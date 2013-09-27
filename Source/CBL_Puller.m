//
//  CBL_Puller.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/2/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBL_Puller.h"
#import "CBLDatabase+Insertion.h"
#import "CBLDatabase+Replication.h"
#import "CBL_Revision.h"
#import "CBLChangeTracker.h"
#import "CBLAuthorizer.h"
#import "CBLBatcher.h"
#import "CBLMultipartDownloader.h"
#import "CBLSequenceMap.h"
#import "CBLInternal.h"
#import "CBLMisc.h"
#import "ExceptionUtils.h"


// Maximum number of revisions to fetch simultaneously. (CFNetwork will only send about 5
// simultaneous requests, but by keeping a larger number in its queue we ensure that it doesn't
// run out, even if the CBL thread doesn't always have time to run.)
#define kMaxOpenHTTPConnections 12

// ?limit= param for _changes feed: max # of revs to get in one batch. Smaller values reduce
// latency since we can't parse till the entire result arrives in longpoll mode. But larger
// values are more efficient because they use fewer HTTP requests.
#define kChangesFeedLimit 100u

// Maximum number of revs to fetch in a single bulk request
#define kMaxRevsToGetInBulk 50u

// Maximum number of revision IDs to pass in an "?atts_since=" query param
#define kMaxNumberOfAttsSince 50u


@interface CBL_Puller () <CBLChangeTrackerClient>
@end


static NSString* joinQuotedEscaped(NSArray* strings);


@implementation CBL_Puller


- (void)dealloc {
    [_changeTracker stop];
}


- (void) beginReplicating {
    if (!_downloadsToInsert) {
        // Note: This is a ref cycle, because the block has a (retained) reference to 'self',
        // and _downloadsToInsert retains the block, and of course I retain _downloadsToInsert.
        _downloadsToInsert = [[CBLBatcher alloc] initWithCapacity: 200 delay: 0.0
                                                  processor: ^(NSArray *downloads) {
                                                      [self insertDownloads: downloads];
                                                  }];
    }
    if (!_pendingSequences) {
        _pendingSequences = [[CBLSequenceMap alloc] init];
        if (_lastSequence != nil) {
            // Prime _pendingSequences so its checkpointedValue will reflect the last known seq:
            SequenceNumber seq = [_pendingSequences addValue: _lastSequence];
            [_pendingSequences removeSequence: seq];
            AssertEqual(_pendingSequences.checkpointedValue, _lastSequence);
        }
    }
    
    _caughtUp = NO;
    [self asyncTaskStarted];   // task: waiting to catch up
    [self startChangeTracker];
}


- (void) startChangeTracker {
    Assert(!_changeTracker);
    CBLChangeTrackerMode mode = (_continuous && _caughtUp) ? kLongPoll : kOneShot;
    
    LogTo(SyncVerbose, @"%@ starting ChangeTracker: mode=%d, since=%@", self, mode, _lastSequence);
    _changeTracker = [[CBLChangeTracker alloc] initWithDatabaseURL: _remote
                                                             mode: mode
                                                        conflicts: YES
                                                     lastSequence: _lastSequence
                                                           client: self];
    // Limit the number of changes to return, so we can parse the feed in parts:
    _changeTracker.limit = kChangesFeedLimit;
    _changeTracker.continuous = _continuous;
    _changeTracker.filterName = _filterName;
    _changeTracker.filterParameters = _filterParameters;
    _changeTracker.docIDs = _docIDs;
    _changeTracker.authorizer = _authorizer;
    unsigned heartbeat = $castIf(NSNumber, _options[kCBLReplicatorOption_Heartbeat]).unsignedIntValue;
    if (heartbeat >= 15000)
        _changeTracker.heartbeat = heartbeat / 1000.0;
    
    NSMutableDictionary* headers = $mdict({@"User-Agent", [CBLRemoteRequest userAgentHeader]});
    [headers addEntriesFromDictionary: _requestHeaders];
    _changeTracker.requestHeaders = headers;
    
    [_changeTracker start];
    if (!_continuous)
        [self asyncTaskStarted];
}


- (void) stop {
    if (!_running)
        return;
    if (_changeTracker) {
        _changeTracker.client = nil;  // stop it from calling my -changeTrackerStopped
        [_changeTracker stop];
        if (!_continuous)
            [self asyncTasksFinished: 1]; // balances -asyncTaskStarted in -startChangeTracker
        if (!_caughtUp)
            [self asyncTasksFinished: 1]; // balances -asyncTaskStarted in -beginReplicating
    }
    _changeTracker = nil;
    _revsToPull = nil;
    _deletedRevsToPull = nil;
    _bulkRevsToPull = nil;
    [super stop];
    
    [_downloadsToInsert flushAll];
}


- (void) retry {
    // This is called if I've gone idle but some revisions failed to be pulled.
    // I should start the _changes feed over again, so I can retry all the revisions.
    [super retry];

    [_changeTracker stop];
    [self beginReplicating];
}


- (void) stopped {
    _downloadsToInsert = nil;
    [super stopped];
}


- (BOOL) goOnline {
    if ([super goOnline])
        return YES;
    // If we were already online (i.e. server is reachable) but got a reachability-change event,
    // tell the tracker to retry in case it's in retry mode after a transient failure. (I.e. the
    // state of the network might be better now.)
    if (_running && _online)
        [_changeTracker retry];
    return NO;
}


- (BOOL) goOffline {
    if (![super goOffline])
        return NO;
    [_changeTracker stop];
    return YES;
}


- (BOOL) changeTrackerApproveSSLTrust: (SecTrustRef)serverTrust
                              forHost: (NSString*)host
                                 port: (UInt16)port
{
    return [self checkSSLServerTrust: serverTrust forHost: host port: port];
}


// Got a _changes feed response from the CBLChangeTracker.
- (void) changeTrackerReceivedChanges: (NSArray*)changes {
    LogTo(Sync, @"%@: Received %u changes", self, (unsigned)changes.count);
    NSUInteger changeCount = 0;
    for (NSDictionary* change in changes) {
        @autoreleasepool {
            // Process each change from the feed:
            id remoteSequenceID = change[@"seq"];
            NSString* docID = change[@"id"];
            if (!docID || ![CBLDatabase isValidDocumentID: docID])
                continue;
            
            BOOL deleted = [change[@"deleted"] isEqual: (id)kCFBooleanTrue];
            NSArray* changes = $castIf(NSArray, change[@"changes"]);
            for (NSDictionary* changeDict in changes) {
                @autoreleasepool {
                    // Push each revision info to the inbox
                    NSString* revID = $castIf(NSString, changeDict[@"rev"]);
                    if (!revID)
                        continue;
                    CBLPulledRevision* rev = [[CBLPulledRevision alloc] initWithDocID: docID
                                                                              revID: revID
                                                                            deleted: deleted];
                    // Remember its remote sequence ID (opaque), and make up a numeric sequence
                    // based on the order in which it appeared in the _changes feed:
                    rev.remoteSequenceID = remoteSequenceID;
                    if (changes.count > 1)
                        rev.conflicted = true;
                    LogTo(SyncVerbose, @"%@: Received #%@ %@", self, remoteSequenceID, rev);
                    [self addToInbox: rev];

                    changeCount++;
                }
            }
        }
    }
    self.changesTotal += changeCount;

    // We can tell we've caught up when the _changes feed returns less than we asked for:
    if (!_caughtUp && changes.count < kChangesFeedLimit) {
        LogTo(Sync, @"%@: Caught up with changes!", self);
        _caughtUp = YES;
        if (_continuous)
            _changeTracker.mode = kLongPoll;
        [self asyncTasksFinished: 1];  // balances -asyncTaskStarted in -beginReplicating
    }
}


// The change tracker reached EOF or an error.
- (void) changeTrackerStopped:(CBLChangeTracker *)tracker {
    if (tracker != _changeTracker)
        return;
    NSError* error = tracker.error;
    LogTo(Sync, @"%@: ChangeTracker stopped; error=%@", self, error.description);
    
    _changeTracker = nil;
    
    if (error) {
        if (CBLIsOfflineError(error))
            [self goOffline];
        else if (!_error)
            self.error = error;
    }
    
    [_batcher flushAll];
    if (!_continuous)
        [self asyncTasksFinished: 1]; // balances -asyncTaskStarted in -startChangeTracker
    if (!_caughtUp)
        [self asyncTasksFinished: 1]; // balances -asyncTaskStarted in -beginReplicating
}


#pragma mark - REVISION CHECKING:


// Process a bunch of remote revisions from the _changes feed at once
- (void) processInbox: (CBL_RevisionList*)inbox {
    // Ask the local database which of the revs are not known to it:
    LogTo(SyncVerbose, @"%@: Looking up %@", self, inbox);
    id lastInboxSequence = [inbox.allRevisions.lastObject remoteSequenceID];
    NSUInteger total = _changesTotal - inbox.count;
    if (![_db findMissingRevisions: inbox]) {
        Warn(@"%@ failed to look up local revs", self);
        inbox = nil;
    }
    if (_changesTotal != total + inbox.count)
        self.changesTotal = total + inbox.count;
    
    if (inbox.count == 0) {
        // Nothing to do; just count all the revisions as processed.
        // Instead of adding and immediately removing the revs to _pendingSequences,
        // just do the latest one (equivalent but faster):
        LogTo(SyncVerbose, @"%@: no new remote revisions to fetch", self);
        SequenceNumber seq = [_pendingSequences addValue: lastInboxSequence];
        [_pendingSequences removeSequence: seq];
        self.lastSequence = _pendingSequences.checkpointedValue;
        return;
    }
    
    LogTo(SyncVerbose, @"%@ queuing remote revisions %@", self, inbox.allRevisions);
    
    // Dump the revs into the queues of revs to pull from the remote db:
    unsigned numBulked = 0;
    for (CBLPulledRevision* rev in inbox.allRevisions) {
        if (rev.generation == 1 && !rev.deleted && !rev.conflicted) {
            // Optimistically pull 1st-gen revs in bulk:
            if (!_bulkRevsToPull) 
                _bulkRevsToPull = [[NSMutableArray alloc] initWithCapacity: 100];
            [_bulkRevsToPull addObject: rev];
            ++numBulked;
        } else {
            [self queueRemoteRevision: rev];
        }
        rev.sequence = [_pendingSequences addValue: rev.remoteSequenceID];
    }
    LogTo(Sync, @"%@ queued %u remote revisions from seq=%@ (%u in bulk, %u individually)",
          self, (unsigned)inbox.count, ((CBLPulledRevision*)inbox[0]).remoteSequenceID,
          numBulked, (unsigned)(inbox.count-numBulked));
    
    [self pullRemoteRevisions];
}


// Add a revision to the appropriate queue of revs to individually GET
- (void) queueRemoteRevision: (CBL_Revision*)rev {
    if (rev.deleted)
    {
        if (!_deletedRevsToPull)
            _deletedRevsToPull = [[NSMutableArray alloc] initWithCapacity:100];
        
        [_deletedRevsToPull addObject:rev];
    }
    else
    {
        if (!_revsToPull)
            _revsToPull = [[NSMutableArray alloc] initWithCapacity:100];
        
        [_revsToPull addObject:rev];
    }
}


// Start up some HTTP GETs, within our limit on the maximum simultaneous number
- (void) pullRemoteRevisions {
    while (_db && _httpConnectionCount < kMaxOpenHTTPConnections) {
        NSUInteger nBulk = MIN(_bulkRevsToPull.count, kMaxRevsToGetInBulk);
        if (nBulk == 1) {
            // Rather than pulling a single revision in 'bulk', just pull it normally:
            [self queueRemoteRevision: _bulkRevsToPull[0]];
            [_bulkRevsToPull removeObjectAtIndex: 0];
            nBulk = 0;
        }
        if (nBulk > 0) {
            // Prefer to pull bulk revisions:
            NSRange r = NSMakeRange(0, nBulk);
            [self pullBulkRevisions: [_bulkRevsToPull subarrayWithRange: r]];
            [_bulkRevsToPull removeObjectsInRange: r];
        } else {
            // Prefer to pull an existing revision over a deleted one:
            NSMutableArray* queue = _revsToPull;
            if (queue.count == 0) {
                queue = _deletedRevsToPull;
                if (queue.count == 0)
                    break;  // both queues are empty
            }
            [self pullRemoteRevision: queue[0]];
            [queue removeObjectAtIndex: 0];
        }
    }
}


// Fetches the contents of a revision from the remote db, including its parent revision ID.
// The contents are stored into rev.properties.
- (void) pullRemoteRevision: (CBL_Revision*)rev
{
    [self asyncTaskStarted];
    ++_httpConnectionCount;
    
    // Construct a query. We want the revision history, and the bodies of attachments.
    // See: http://wiki.apache.org/couchdb/HTTP_Document_API#GET
    // See: http://wiki.apache.org/couchdb/HTTP_Document_API#Getting_Attachments_With_a_Document
    NSString* path = $sprintf(@"%@?rev=%@&revs=true&attachments=true",
                              CBLEscapeID(rev.docID), CBLEscapeID(rev.revID));
    // If the document has attachments, add an 'atts_since' param with a list of
    // already-known revisions, so the server can skip sending the bodies of any
    // attachments we already have locally:
    BOOL hasAttachment;
    NSArray* knownRevs = [_db getPossibleAncestorRevisionIDs: rev
                                                       limit: kMaxNumberOfAttsSince
                                               hasAttachment: &hasAttachment];
    if (hasAttachment && knownRevs.count > 0)
        path = [path stringByAppendingFormat: @"&atts_since=%@", joinQuotedEscaped(knownRevs)];
    LogTo(SyncVerbose, @"%@: GET %@", self, path);
    
    // Under ARC, using variable dl directly in the block given as an argument to initWithURL:...
    // results in compiler error (could be undefined variable)
    __weak CBL_Puller *weakSelf = self;
    CBLMultipartDownloader *dl;
    dl = [[CBLMultipartDownloader alloc] initWithURL: CBLAppendToURL(_remote, path)
                                           database: _db
                                     requestHeaders: self.requestHeaders
                                       onCompletion:
        ^(CBLMultipartDownloader* dl, NSError *error) {
            __strong CBL_Puller *strongSelf = weakSelf;
            // OK, now we've got the response revision:
            if (error) {
                strongSelf.error = error;
                [strongSelf revisionFailed];
                strongSelf.changesProcessed++;
            } else {
                CBL_Revision* gotRev = [CBL_Revision revisionWithProperties: dl.document];
                gotRev.sequence = rev.sequence;
                // Add to batcher ... eventually it will be fed to -insertRevisions:.
                [_downloadsToInsert queueObject: gotRev];
                [strongSelf asyncTaskStarted];
            }
            
            // Note that we've finished this task:
            [strongSelf removeRemoteRequest:dl];
            [strongSelf asyncTasksFinished:1];
            --_httpConnectionCount;
            // Start another task if there are still revisions waiting to be pulled:
            [strongSelf pullRemoteRevisions];
        }
     ];
    [self addRemoteRequest: dl];
    dl.timeoutInterval = self.requestTimeout;
    dl.authorizer = _authorizer;
    [dl start];
}


// Get a bunch of revisions in one bulk request.
- (void) pullBulkRevisions: (NSArray*)bulkRevs {
    // http://wiki.apache.org/couchdb/HTTP_Bulk_Document_API
    NSUInteger nRevs = bulkRevs.count;
    if (nRevs == 0)
        return;
    LogTo(Sync, @"%@ bulk-fetching %u remote revisions...", self, (unsigned)nRevs);
    LogTo(SyncVerbose, @"%@ bulk-fetching remote revisions: %@", self, bulkRevs);
    
    [self asyncTaskStarted];
    ++_httpConnectionCount;
    NSMutableArray* remainingRevs = [bulkRevs mutableCopy];
    NSArray* keys = [bulkRevs my_map: ^(CBL_Revision* rev) { return rev.docID; }];
    [self sendAsyncRequest: @"POST"
                      path: @"_all_docs?include_docs=true"
                      body: $dict({@"keys", keys})
              onCompletion:^(id result, NSError *error) {
                  if (error) {
                      self.error = error;
                      [self revisionFailed];
                      self.changesProcessed += bulkRevs.count;
                  } else {
                      // Process the resulting rows' documents.
                      // We only add a document if it doesn't have attachments, and if its
                      // revID matches the one we asked for.
                      NSArray* rows = $castIf(NSArray, result[@"rows"]);
                      LogTo(Sync, @"%@ checking %u bulk-fetched remote revisions",
                            self, (unsigned)rows.count);
                      for (NSDictionary* row in rows) {
                          NSDictionary* doc = $castIf(NSDictionary, row[@"doc"]);
                          if (doc && !doc[@"_attachments"]) {
                              CBL_Revision* rev = [CBL_Revision revisionWithProperties: doc];
                              NSUInteger pos = [remainingRevs indexOfObject: rev];
                              if (pos != NSNotFound) {
                                  rev.sequence = [remainingRevs[pos] sequence];
                                  [remainingRevs removeObjectAtIndex: pos];
                                  [_downloadsToInsert queueObject: rev];
                                  [self asyncTaskStarted];
                              }
                          }
                      }
                  }
                  
                  // Any leftover revisions that didn't get matched will be fetched individually:
                  if (remainingRevs.count) {
                      LogTo(Sync, @"%@ bulk-fetch didn't work for %u of %u revs; getting individually",
                            self, (unsigned)remainingRevs.count, (unsigned)nRevs);
                      for (CBL_Revision* rev in remainingRevs)
                          [self queueRemoteRevision: rev];
                      [self pullRemoteRevisions];
                  }

                  // Note that we've finished this task:
                  [self asyncTasksFinished: 1];
                  --_httpConnectionCount;
                  // Start another task if there are still revisions waiting to be pulled:
                  [self pullRemoteRevisions];
              }
     ];
}


// This will be called when _downloadsToInsert fills up:
- (void) insertDownloads:(NSArray *)downloads {
    LogTo(SyncVerbose, @"%@ inserting %u revisions...", self, (unsigned)downloads.count);
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();
        
    downloads = [downloads sortedArrayUsingSelector: @selector(compareSequences:)];
    [_db _inTransaction: ^CBLStatus {
        for (CBL_Revision* rev in downloads) {
            @autoreleasepool {
                SequenceNumber fakeSequence = rev.sequence;
                NSArray* history = [CBLDatabase parseCouchDBRevisionHistory: rev.properties];
                if (!history && rev.generation > 1) {
                    Warn(@"%@: Missing revision history in response for %@", self, rev);
                    self.error = CBLStatusToNSError(kCBLStatusUpstreamError, nil);
                    [self revisionFailed];
                    continue;
                }
                LogTo(SyncVerbose, @"%@ inserting %@ %@",
                      self, rev.docID, [history my_compactDescription]);

                // Insert the revision:
                int status = [_db forceInsert: rev revisionHistory: history source: _remote];
                if (CBLStatusIsError(status)) {
                    if (status == kCBLStatusForbidden) {
                        // Considered a success, since the doc was delivered to the app.
                        LogTo(Sync, @"%@: Remote rev failed validation: %@", self, rev);
                    } else if (status == kCBLStatusDBBusy) {
                        return status;  // abort transaction; _inTransaction will retry
                    } else {
                        Warn(@"%@ failed to write %@: status=%d", self, rev, status);
                        [self revisionFailed];
                        self.error = CBLStatusToNSError(status, nil);
                        continue;
                    }
                }
                
                // Mark this revision's fake sequence as processed:
                [_pendingSequences removeSequence: fakeSequence];
            }
        }
        
        LogTo(SyncVerbose, @"%@ finished inserting %u revisions",
              self, (unsigned)downloads.count);
        return kCBLStatusOK;
    }];

    // Checkpoint:
    self.lastSequence = _pendingSequences.checkpointedValue;

    time = CFAbsoluteTimeGetCurrent() - time;
    LogTo(Sync, @"%@ inserted %u revs in %.3f sec (%.1f/sec)",
          self, (unsigned)downloads.count, time, downloads.count/time);
    
    [self asyncTasksFinished: downloads.count];
    self.changesProcessed += downloads.count;
}


@end



#pragma mark -

@implementation CBLPulledRevision

@synthesize remoteSequenceID=_remoteSequenceID, conflicted=_conflicted;


@end



static NSString* joinQuotedEscaped(NSArray* strings) {
    if (strings.count == 0)
        return @"[]";
    NSString* json = [CBLJSON stringWithJSONObject: strings options: 0 error: NULL];
    return CBLEscapeURLParam(json);
}
