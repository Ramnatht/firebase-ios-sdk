/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>

#include <memory>
#include <utility>
#include <vector>

#import "Firestore/Source/Core/FSTEventManager.h"
#import "Firestore/Source/Core/FSTQuery.h"
#import "Firestore/Source/Core/FSTView.h"
#import "Firestore/Source/Model/FSTDocument.h"
#import "Firestore/Source/Util/FSTAsyncQueryListener.h"

#import "Firestore/Example/Tests/Util/FSTHelpers.h"

#include "Firestore/core/include/firebase/firestore/firestore_errors.h"
#include "Firestore/core/src/firebase/firestore/core/view_snapshot.h"
#include "Firestore/core/src/firebase/firestore/model/document_set.h"
#include "Firestore/core/src/firebase/firestore/model/types.h"
#include "Firestore/core/src/firebase/firestore/remote/remote_event.h"
#include "Firestore/core/src/firebase/firestore/util/delayed_constructor.h"
#include "Firestore/core/src/firebase/firestore/util/executor_libdispatch.h"
#include "Firestore/core/src/firebase/firestore/util/status.h"
#include "Firestore/core/src/firebase/firestore/util/statusor.h"
#include "Firestore/core/test/firebase/firestore/testutil/xcgmock.h"

using firebase::firestore::FirestoreErrorCode;
using firebase::firestore::core::DocumentViewChange;
using firebase::firestore::core::ViewSnapshot;
using firebase::firestore::core::ViewSnapshotHandler;
using firebase::firestore::model::DocumentKeySet;
using firebase::firestore::model::DocumentSet;
using firebase::firestore::model::OnlineState;
using firebase::firestore::remote::TargetChange;
using firebase::firestore::util::DelayedConstructor;
using firebase::firestore::util::ExecutorLibdispatch;
using firebase::firestore::util::Status;
using firebase::firestore::util::StatusOr;
using testing::ElementsAre;
using testing::IsEmpty;

NS_ASSUME_NONNULL_BEGIN

namespace {

ViewSnapshot ExcludingMetadataChanges(const ViewSnapshot &snapshot) {
  return ViewSnapshot{
      snapshot.query(),
      snapshot.documents(),
      snapshot.old_documents(),
      snapshot.document_changes(),
      snapshot.mutated_keys(),
      snapshot.from_cache(),
      snapshot.sync_state_changed(),
      /*excludes_metadata_changes=*/true,
  };
}

}  // namespace

@interface FSTQueryListenerTests : XCTestCase
@end

@implementation FSTQueryListenerTests {
  DelayedConstructor<ExecutorLibdispatch> _executor;
  FSTListenOptions *_includeMetadataChanges;
}

- (void)setUp {
  _executor.Init(dispatch_queue_create("FSTQueryListenerTests Queue", DISPATCH_QUEUE_SERIAL));
  _includeMetadataChanges = [[FSTListenOptions alloc] initWithIncludeQueryMetadataChanges:YES
                                                           includeDocumentMetadataChanges:YES
                                                                    waitForSyncWhenOnline:NO];
}

- (void)testRaisesCollectionEvents {
  std::vector<ViewSnapshot> accum;
  std::vector<ViewSnapshot> otherAccum;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTDocument *doc1 = FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateSynced);
  FSTDocument *doc2 = FSTTestDoc("rooms/Hades", 2, @{@"name" : @"Hades"}, FSTDocumentStateSynced);
  FSTDocument *doc2prime = FSTTestDoc("rooms/Hades", 3, @{@"name" : @"Hades", @"owner" : @"Jonny"},
                                      FSTDocumentStateSynced);

  FSTQueryListener *listener = [self listenToQuery:query
                                           options:_includeMetadataChanges
                             accumulatingSnapshots:&accum];
  FSTQueryListener *otherListener = [self listenToQuery:query accumulatingSnapshots:&otherAccum];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[ doc1, doc2 ], absl::nullopt).value();
  ViewSnapshot snap2 = FSTTestApplyChanges(view, @[ doc2prime ], absl::nullopt).value();

  DocumentViewChange change1{doc1, DocumentViewChange::Type::kAdded};
  DocumentViewChange change2{doc2, DocumentViewChange::Type::kAdded};
  DocumentViewChange change3{doc2prime, DocumentViewChange::Type::kModified};
  DocumentViewChange change4{doc2prime, DocumentViewChange::Type::kAdded};

  [listener queryDidChangeViewSnapshot:snap1];
  [listener queryDidChangeViewSnapshot:snap2];
  [otherListener queryDidChangeViewSnapshot:snap2];

  XC_ASSERT_THAT(accum, ElementsAre(snap1, snap2));
  XC_ASSERT_THAT(accum[0].document_changes(), ElementsAre(change1, change2));
  XC_ASSERT_THAT(accum[1].document_changes(), ElementsAre(change3));

  ViewSnapshot expectedSnap2{snap2.query(),
                             snap2.documents(),
                             /*old_documents=*/DocumentSet{snap2.query().comparator},
                             /*document_changes=*/{change1, change4},
                             snap2.mutated_keys(),
                             snap2.from_cache(),
                             /*sync_state_changed=*/true,
                             /*excludes_metadata_changes=*/true};
  XC_ASSERT_THAT(otherAccum, ElementsAre(expectedSnap2));
}

- (void)testRaisesErrorEvent {
  __block std::vector<Status> accum;
  FSTQuery *query = FSTTestQuery("rooms/Eros");

  FSTQueryListener *listener = [self listenToQuery:query
                                           handler:^(const StatusOr<ViewSnapshot> &maybe_snapshot) {
                                             accum.push_back(maybe_snapshot.status());
                                           }];

  Status testError{FirestoreErrorCode::Unauthenticated, "Some info"};
  [listener queryDidError:testError];

  XC_ASSERT_THAT(accum, ElementsAre(testError));
}

- (void)testRaisesEventForEmptyCollectionAfterSync {
  std::vector<ViewSnapshot> accum;
  FSTQuery *query = FSTTestQuery("rooms");

  FSTQueryListener *listener = [self listenToQuery:query
                                           options:_includeMetadataChanges
                             accumulatingSnapshots:&accum];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[], absl::nullopt).value();
  ViewSnapshot snap2 = FSTTestApplyChanges(view, @[], FSTTestTargetChangeMarkCurrent()).value();

  [listener queryDidChangeViewSnapshot:snap1];
  XC_ASSERT_THAT(accum, IsEmpty());

  [listener queryDidChangeViewSnapshot:snap2];
  XC_ASSERT_THAT(accum, ElementsAre(snap2));
}

- (void)testMutingAsyncListenerPreventsAllSubsequentEvents {
  __block std::vector<ViewSnapshot> accum;

  FSTQuery *query = FSTTestQuery("rooms/Eros");
  FSTDocument *doc1 = FSTTestDoc("rooms/Eros", 3, @{@"name" : @"Eros"}, FSTDocumentStateSynced);
  FSTDocument *doc2 = FSTTestDoc("rooms/Eros", 4, @{@"name" : @"Eros2"}, FSTDocumentStateSynced);

  __block FSTAsyncQueryListener *listener = [[FSTAsyncQueryListener alloc]
      initWithExecutor:_executor.get()
       snapshotHandler:^(const StatusOr<ViewSnapshot> &maybe_snapshot) {
         accum.push_back(maybe_snapshot.ValueOrDie());
         [listener mute];
       }];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot viewSnapshot1 = FSTTestApplyChanges(view, @[ doc1 ], absl::nullopt).value();
  ViewSnapshot viewSnapshot2 = FSTTestApplyChanges(view, @[ doc2 ], absl::nullopt).value();

  ViewSnapshotHandler handler = listener.asyncSnapshotHandler;
  handler(viewSnapshot1);
  handler(viewSnapshot2);

  // Drain queue
  XCTestExpectation *expectation = [self expectationWithDescription:@"Queue drained"];
  _executor->Execute([=] { [expectation fulfill]; });

  [self waitForExpectationsWithTimeout:4.0
                               handler:^(NSError *_Nullable expectationError) {
                                 if (expectationError) {
                                   XCTFail(@"Error waiting for timeout: %@", expectationError);
                                 }
                               }];

  // We should get the first snapshot but not the second.
  XC_ASSERT_THAT(accum, ElementsAre(viewSnapshot1));
}

- (void)testDoesNotRaiseEventsForMetadataChangesUnlessSpecified {
  std::vector<ViewSnapshot> filteredAccum;
  std::vector<ViewSnapshot> fullAccum;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTDocument *doc1 = FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateSynced);
  FSTDocument *doc2 = FSTTestDoc("rooms/Hades", 2, @{@"name" : @"Hades"}, FSTDocumentStateSynced);

  FSTQueryListener *filteredListener = [self listenToQuery:query
                                     accumulatingSnapshots:&filteredAccum];
  FSTQueryListener *fullListener = [self listenToQuery:query
                                               options:_includeMetadataChanges
                                 accumulatingSnapshots:&fullAccum];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[ doc1 ], absl::nullopt).value();

  TargetChange ackTarget = FSTTestTargetChangeAckDocuments({doc1.key});
  ViewSnapshot snap2 = FSTTestApplyChanges(view, @[], ackTarget).value();
  ViewSnapshot snap3 = FSTTestApplyChanges(view, @[ doc2 ], absl::nullopt).value();

  [filteredListener queryDidChangeViewSnapshot:snap1];  // local event
  [filteredListener queryDidChangeViewSnapshot:snap2];  // no event
  [filteredListener queryDidChangeViewSnapshot:snap3];  // doc2 update

  [fullListener queryDidChangeViewSnapshot:snap1];  // local event
  [fullListener queryDidChangeViewSnapshot:snap2];  // state change event
  [fullListener queryDidChangeViewSnapshot:snap3];  // doc2 update

  XC_ASSERT_THAT(filteredAccum,
                 ElementsAre(ExcludingMetadataChanges(snap1), ExcludingMetadataChanges(snap3)));
  XC_ASSERT_THAT(fullAccum, ElementsAre(snap1, snap2, snap3));
}

- (void)testRaisesDocumentMetadataEventsOnlyWhenSpecified {
  std::vector<ViewSnapshot> filteredAccum;
  std::vector<ViewSnapshot> fullAccum;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTDocument *doc1 =
      FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateLocalMutations);
  FSTDocument *doc2 = FSTTestDoc("rooms/Hades", 2, @{@"name" : @"Hades"}, FSTDocumentStateSynced);
  FSTDocument *doc1Prime =
      FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateSynced);
  FSTDocument *doc3 = FSTTestDoc("rooms/Other", 3, @{@"name" : @"Other"}, FSTDocumentStateSynced);

  FSTListenOptions *options = [[FSTListenOptions alloc] initWithIncludeQueryMetadataChanges:NO
                                                             includeDocumentMetadataChanges:YES
                                                                      waitForSyncWhenOnline:NO];

  FSTQueryListener *filteredListener = [self listenToQuery:query
                                     accumulatingSnapshots:&filteredAccum];
  FSTQueryListener *fullListener = [self listenToQuery:query
                                               options:options
                                 accumulatingSnapshots:&fullAccum];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[ doc1, doc2 ], absl::nullopt).value();
  ViewSnapshot snap2 = FSTTestApplyChanges(view, @[ doc1Prime ], absl::nullopt).value();
  ViewSnapshot snap3 = FSTTestApplyChanges(view, @[ doc3 ], absl::nullopt).value();

  DocumentViewChange change1{doc1, DocumentViewChange::Type::kAdded};
  DocumentViewChange change2{doc2, DocumentViewChange::Type::kAdded};
  DocumentViewChange change3{doc1Prime, DocumentViewChange::Type::kMetadata};
  DocumentViewChange change4{doc3, DocumentViewChange::Type::kAdded};

  [filteredListener queryDidChangeViewSnapshot:snap1];
  [filteredListener queryDidChangeViewSnapshot:snap2];
  [filteredListener queryDidChangeViewSnapshot:snap3];
  [fullListener queryDidChangeViewSnapshot:snap1];
  [fullListener queryDidChangeViewSnapshot:snap2];
  [fullListener queryDidChangeViewSnapshot:snap3];

  XC_ASSERT_THAT(filteredAccum,
                 ElementsAre(ExcludingMetadataChanges(snap1), ExcludingMetadataChanges(snap3)));
  XC_ASSERT_THAT(filteredAccum[0].document_changes(), ElementsAre(change1, change2));
  XC_ASSERT_THAT(filteredAccum[1].document_changes(), ElementsAre(change4));

  XC_ASSERT_THAT(fullAccum, ElementsAre(snap1, snap2, snap3));
  XC_ASSERT_THAT(fullAccum[0].document_changes(), ElementsAre(change1, change2));
  XC_ASSERT_THAT(fullAccum[1].document_changes(), ElementsAre(change3));
  XC_ASSERT_THAT(fullAccum[2].document_changes(), ElementsAre(change4));
}

- (void)testRaisesQueryMetadataEventsOnlyWhenHasPendingWritesOnTheQueryChanges {
  std::vector<ViewSnapshot> fullAccum;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTDocument *doc1 =
      FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateLocalMutations);
  FSTDocument *doc2 =
      FSTTestDoc("rooms/Hades", 2, @{@"name" : @"Hades"}, FSTDocumentStateLocalMutations);
  FSTDocument *doc1Prime =
      FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateSynced);
  FSTDocument *doc2Prime =
      FSTTestDoc("rooms/Hades", 2, @{@"name" : @"Hades"}, FSTDocumentStateSynced);
  FSTDocument *doc3 = FSTTestDoc("rooms/Other", 3, @{@"name" : @"Other"}, FSTDocumentStateSynced);

  FSTListenOptions *options = [[FSTListenOptions alloc] initWithIncludeQueryMetadataChanges:YES
                                                             includeDocumentMetadataChanges:NO
                                                                      waitForSyncWhenOnline:NO];
  FSTQueryListener *fullListener = [self listenToQuery:query
                                               options:options
                                 accumulatingSnapshots:&fullAccum];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[ doc1, doc2 ], absl::nullopt).value();
  ViewSnapshot snap2 = FSTTestApplyChanges(view, @[ doc1Prime ], absl::nullopt).value();
  ViewSnapshot snap3 = FSTTestApplyChanges(view, @[ doc3 ], absl::nullopt).value();
  ViewSnapshot snap4 = FSTTestApplyChanges(view, @[ doc2Prime ], absl::nullopt).value();

  [fullListener queryDidChangeViewSnapshot:snap1];
  [fullListener queryDidChangeViewSnapshot:snap2];  // Emits no events.
  [fullListener queryDidChangeViewSnapshot:snap3];
  [fullListener queryDidChangeViewSnapshot:snap4];  // Metadata change event.

  ViewSnapshot expectedSnap4{
      snap4.query(),
      snap4.documents(),
      snap3.documents(),
      /*document_changes=*/{},
      snap4.mutated_keys(),
      snap4.from_cache(),
      snap4.sync_state_changed(),
      /*excludes_metadata_changes=*/true  // This test excludes document metadata changes
  };

  XC_ASSERT_THAT(fullAccum, ElementsAre(ExcludingMetadataChanges(snap1),
                                        ExcludingMetadataChanges(snap3), expectedSnap4));
}

- (void)testMetadataOnlyDocumentChangesAreFilteredOutWhenIncludeDocumentMetadataChangesIsFalse {
  std::vector<ViewSnapshot> filteredAccum;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTDocument *doc1 =
      FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateLocalMutations);
  FSTDocument *doc2 = FSTTestDoc("rooms/Hades", 2, @{@"name" : @"Hades"}, FSTDocumentStateSynced);
  FSTDocument *doc1Prime =
      FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateSynced);
  FSTDocument *doc3 = FSTTestDoc("rooms/Other", 3, @{@"name" : @"Other"}, FSTDocumentStateSynced);

  FSTQueryListener *filteredListener = [self listenToQuery:query
                                     accumulatingSnapshots:&filteredAccum];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[ doc1, doc2 ], absl::nullopt).value();
  ViewSnapshot snap2 = FSTTestApplyChanges(view, @[ doc1Prime, doc3 ], absl::nullopt).value();

  DocumentViewChange change3{doc3, DocumentViewChange::Type::kAdded};

  [filteredListener queryDidChangeViewSnapshot:snap1];
  [filteredListener queryDidChangeViewSnapshot:snap2];

  ViewSnapshot expectedSnap2{snap2.query(),
                             snap2.documents(),
                             snap1.documents(),
                             /*document_changes=*/{change3},
                             snap2.mutated_keys(),
                             snap2.from_cache(),
                             snap2.sync_state_changed(),
                             /*excludes_metadata_changes=*/true};
  XC_ASSERT_THAT(filteredAccum, ElementsAre(ExcludingMetadataChanges(snap1), expectedSnap2));
}

- (void)testWillWaitForSyncIfOnline {
  std::vector<ViewSnapshot> events;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTDocument *doc1 = FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateSynced);
  FSTDocument *doc2 = FSTTestDoc("rooms/Hades", 2, @{@"name" : @"Hades"}, FSTDocumentStateSynced);
  FSTQueryListener *listener =
      [self listenToQuery:query
                        options:[[FSTListenOptions alloc] initWithIncludeQueryMetadataChanges:NO
                                                               includeDocumentMetadataChanges:NO
                                                                        waitForSyncWhenOnline:YES]
          accumulatingSnapshots:&events];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[ doc1 ], absl::nullopt).value();
  ViewSnapshot snap2 = FSTTestApplyChanges(view, @[ doc2 ], absl::nullopt).value();
  ViewSnapshot snap3 =
      FSTTestApplyChanges(view, @[], FSTTestTargetChangeAckDocuments({doc1.key, doc2.key})).value();

  [listener applyChangedOnlineState:OnlineState::Online];  // no event
  [listener queryDidChangeViewSnapshot:snap1];
  [listener applyChangedOnlineState:OnlineState::Unknown];
  [listener applyChangedOnlineState:OnlineState::Online];
  [listener queryDidChangeViewSnapshot:snap2];
  [listener queryDidChangeViewSnapshot:snap3];

  DocumentViewChange change1{doc1, DocumentViewChange::Type::kAdded};
  DocumentViewChange change2{doc2, DocumentViewChange::Type::kAdded};
  ViewSnapshot expectedSnap{snap3.query(),
                            snap3.documents(),
                            /*old_documents=*/DocumentSet{snap3.query().comparator},
                            /*document_changes=*/{change1, change2},
                            snap3.mutated_keys(),
                            /*from_cache=*/false,
                            /*sync_state_changed=*/true,
                            /*excludes_metadata_changes=*/true};
  XC_ASSERT_THAT(events, ElementsAre(expectedSnap));
}

- (void)testWillRaiseInitialEventWhenGoingOffline {
  std::vector<ViewSnapshot> events;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTDocument *doc1 = FSTTestDoc("rooms/Eros", 1, @{@"name" : @"Eros"}, FSTDocumentStateSynced);
  FSTDocument *doc2 = FSTTestDoc("rooms/Hades", 2, @{@"name" : @"Hades"}, FSTDocumentStateSynced);
  FSTQueryListener *listener =
      [self listenToQuery:query
                        options:[[FSTListenOptions alloc] initWithIncludeQueryMetadataChanges:NO
                                                               includeDocumentMetadataChanges:NO
                                                                        waitForSyncWhenOnline:YES]
          accumulatingSnapshots:&events];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[ doc1 ], absl::nullopt).value();
  ViewSnapshot snap2 = FSTTestApplyChanges(view, @[ doc2 ], absl::nullopt).value();

  [listener applyChangedOnlineState:OnlineState::Online];   // no event
  [listener queryDidChangeViewSnapshot:snap1];              // no event
  [listener applyChangedOnlineState:OnlineState::Offline];  // event
  [listener applyChangedOnlineState:OnlineState::Unknown];  // no event
  [listener applyChangedOnlineState:OnlineState::Offline];  // no event
  [listener queryDidChangeViewSnapshot:snap2];              // another event

  DocumentViewChange change1{doc1, DocumentViewChange::Type::kAdded};
  DocumentViewChange change2{doc2, DocumentViewChange::Type::kAdded};
  ViewSnapshot expectedSnap1{query,
                             /*documents=*/snap1.documents(),
                             /*old_documents=*/DocumentSet{snap1.query().comparator},
                             /*document_changes=*/{change1},
                             snap1.mutated_keys(),
                             /*from_cache=*/true,
                             /*sync_state_changed=*/true,
                             /*excludes_metadata_changes=*/true};

  ViewSnapshot expectedSnap2{query,
                             /*documents=*/snap2.documents(),
                             /*old_documents=*/snap1.documents(),
                             /*document_changes=*/{change2},
                             snap2.mutated_keys(),
                             /*from_cache=*/true,
                             /*sync_state_changed=*/false,
                             /*excludes_metadata_changes=*/true};
  XC_ASSERT_THAT(events, ElementsAre(expectedSnap1, expectedSnap2));
}

- (void)testWillRaiseInitialEventWhenGoingOfflineAndThereAreNoDocs {
  std::vector<ViewSnapshot> events;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTQueryListener *listener = [self listenToQuery:query
                                           options:[FSTListenOptions defaultOptions]
                             accumulatingSnapshots:&events];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[], absl::nullopt).value();

  [listener applyChangedOnlineState:OnlineState::Online];   // no event
  [listener queryDidChangeViewSnapshot:snap1];              // no event
  [listener applyChangedOnlineState:OnlineState::Offline];  // event

  ViewSnapshot expectedSnap{query,
                            /*documents=*/snap1.documents(),
                            /*old_documents=*/DocumentSet{snap1.query().comparator},
                            /*document_changes=*/{},
                            snap1.mutated_keys(),
                            /*from_cache=*/true,
                            /*sync_state_changed=*/true,
                            /*excludes_metadata_changes=*/true};
  XC_ASSERT_THAT(events, ElementsAre(expectedSnap));
}

- (void)testWillRaiseInitialEventWhenStartingOfflineAndThereAreNoDocs {
  std::vector<ViewSnapshot> events;

  FSTQuery *query = FSTTestQuery("rooms");
  FSTQueryListener *listener = [self listenToQuery:query
                                           options:[FSTListenOptions defaultOptions]
                             accumulatingSnapshots:&events];

  FSTView *view = [[FSTView alloc] initWithQuery:query remoteDocuments:DocumentKeySet{}];
  ViewSnapshot snap1 = FSTTestApplyChanges(view, @[], absl::nullopt).value();

  [listener applyChangedOnlineState:OnlineState::Offline];  // no event
  [listener queryDidChangeViewSnapshot:snap1];              // event

  ViewSnapshot expectedSnap{query,
                            /*documents=*/snap1.documents(),
                            /*old_documents=*/DocumentSet{snap1.query().comparator},
                            /*document_changes=*/{},
                            snap1.mutated_keys(),
                            /*from_cache=*/true,
                            /*sync_state_changed=*/true,
                            /*excludes_metadata_changes=*/true};
  XC_ASSERT_THAT(events, ElementsAre(expectedSnap));
}

- (FSTQueryListener *)listenToQuery:(FSTQuery *)query handler:(ViewSnapshotHandler &&)handler {
  return [[FSTQueryListener alloc] initWithQuery:query
                                         options:[FSTListenOptions defaultOptions]
                             viewSnapshotHandler:std::move(handler)];
}

- (FSTQueryListener *)listenToQuery:(FSTQuery *)query
                            options:(FSTListenOptions *)options
              accumulatingSnapshots:(std::vector<ViewSnapshot> *)values {
  return [[FSTQueryListener alloc] initWithQuery:query
                                         options:options
                             viewSnapshotHandler:^(const StatusOr<ViewSnapshot> &maybe_snapshot) {
                               values->push_back(maybe_snapshot.ValueOrDie());
                             }];
}

- (FSTQueryListener *)listenToQuery:(FSTQuery *)query
              accumulatingSnapshots:(std::vector<ViewSnapshot> *)values {
  return [self listenToQuery:query
                     options:[FSTListenOptions defaultOptions]
       accumulatingSnapshots:values];
}

@end

NS_ASSUME_NONNULL_END
