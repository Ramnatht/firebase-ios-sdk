/*
 * Copyright 2020 Google LLC
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

#import <OCMock/OCMock.h>
#import "FBLPromise+Testing.h"

@import FirebaseCoreInternal;

#import <GoogleUtilities/GULURLSessionDataResponse.h>
#import <GoogleUtilities/NSURLSession+GULPromises.h>

#import "FirebaseAppCheck/Sources/Core/APIService/FIRAppCheckAPIService.h"
#import "FirebaseAppCheck/Sources/Core/Errors/FIRAppCheckErrorUtil.h"
#import "FirebaseAppCheck/Sources/Public/FirebaseAppCheck/FIRAppCheckErrors.h"
#import "FirebaseAppCheck/Sources/Public/FirebaseAppCheck/FIRAppCheckToken.h"

#import "FirebaseAppCheck/Tests/Unit/Utils/FIRFixtureLoader.h"
#import "SharedTestUtilities/Date/FIRDateTestUtils.h"
#import "SharedTestUtilities/URLSession/FIRURLSessionOCMockStub.h"

#import "FirebaseCore/Extension/FirebaseCoreInternal.h"

#pragma mark - Fakes

/// A fake heartbeat logger used for dependency injection during testing.
@interface FIRHeartbeatLoggerFake : NSObject <FIRHeartbeatLoggerProtocol>
@property(nonatomic, copy, nullable) FIRHeartbeatsPayload * (^onFlushHeartbeatsIntoPayloadHandler)
    (void);
@property(nonatomic, copy, nullable) FIRDailyHeartbeatCode (^onHeartbeatCodeForTodayHandler)(void);
@end

@implementation FIRHeartbeatLoggerFake

- (nonnull FIRHeartbeatsPayload *)flushHeartbeatsIntoPayload {
  if (self.onFlushHeartbeatsIntoPayloadHandler) {
    return self.onFlushHeartbeatsIntoPayloadHandler();
  } else {
    return nil;
  }
}

- (FIRDailyHeartbeatCode)heartbeatCodeForToday {
  // This API should not be used by the below tests because the AppCheck SDK
  // uses only the V2 heartbeat API (`flushHeartbeatsIntoPayload`) for getting
  // heartbeats.
  [self doesNotRecognizeSelector:_cmd];
  return FIRDailyHeartbeatCodeNone;
}

- (void)log {
  // This API should not be used by the below tests because the AppCheck SDK
  // does not log heartbeats in it's networking context.
  [self doesNotRecognizeSelector:_cmd];
}

@end

#pragma mark - FIRAppCheckAPIServiceTests

@interface FIRAppCheckAPIServiceTests : XCTestCase

@property(nonatomic) FIRAppCheckAPIService *APIService;

@property(nonatomic) id mockURLSession;

@property(nonatomic) NSString *APIKey;
@property(nonatomic) NSString *appID;

@property(nonatomic) FIRHeartbeatLoggerFake *heartbeatLoggerFake;

@end

@implementation FIRAppCheckAPIServiceTests

- (void)setUp {
  [super setUp];

  self.APIKey = @"api_key";
  self.appID = @"app_id";

  self.mockURLSession = OCMStrictClassMock([NSURLSession class]);

  self.heartbeatLoggerFake = [[FIRHeartbeatLoggerFake alloc] init];
  self.APIService = [[FIRAppCheckAPIService alloc] initWithURLSession:self.mockURLSession
                                                               APIKey:self.APIKey
                                                                appID:self.appID
                                                      heartbeatLogger:self.heartbeatLoggerFake];
}

- (void)tearDown {
  [super tearDown];

  self.APIService = nil;
  [self.mockURLSession stopMocking];
  self.mockURLSession = nil;
}

- (void)testDataRequestSuccessWhenNoHeartbeatsNeedSending {
  // Given
  FIRHeartbeatsPayload *emptyHeartbeatsPayload =
      [FIRHeartbeatLoggingTestUtils emptyHeartbeatsPayload];
  // When
  self.heartbeatLoggerFake.onFlushHeartbeatsIntoPayloadHandler = ^FIRHeartbeatsPayload * {
    return emptyHeartbeatsPayload;
  };
  // Then
  [self assertDataRequestSuccessWhenSendingHeartbeatsPayload:emptyHeartbeatsPayload];
}

- (void)testDataRequestSuccessWhenHeartbeatsNeedSending {
  // Given
  FIRHeartbeatsPayload *nonEmptyHeartbeatsPayload =
      [FIRHeartbeatLoggingTestUtils nonEmptyHeartbeatsPayload];
  // When
  self.heartbeatLoggerFake.onFlushHeartbeatsIntoPayloadHandler = ^FIRHeartbeatsPayload * {
    return nonEmptyHeartbeatsPayload;
  };
  // Then
  [self assertDataRequestSuccessWhenSendingHeartbeatsPayload:nonEmptyHeartbeatsPayload];
}

- (void)testDataRequestNetworkError {
  NSURL *URL = [NSURL URLWithString:@"https://some.url.com"];
  NSDictionary *additionalHeaders = @{@"header1" : @"value1"};
  NSData *requestBody = [@"Request body" dataUsingEncoding:NSUTF8StringEncoding];

  // 1. Stub URL session.
  NSError *networkError = [NSError errorWithDomain:self.name code:-1 userInfo:nil];

  [self stubURLSessionDataTaskPromiseWithResponse:nil
                                             body:nil
                                            error:networkError
                                   URLSessionMock:self.mockURLSession
                           requestValidationBlock:nil];

  // 2. Send request.
  __auto_type requestPromise = [self.APIService sendRequestWithURL:URL
                                                        HTTPMethod:@"POST"
                                                              body:requestBody
                                                 additionalHeaders:additionalHeaders];

  // 3. Verify.
  XCTAssert(FBLWaitForPromisesWithTimeout(1));

  XCTAssertTrue(requestPromise.isRejected);
  XCTAssertNotNil(requestPromise.error);
  XCTAssertEqualObjects(requestPromise.error.domain, FIRAppCheckErrorDomain);
  XCTAssertEqual(requestPromise.error.code, FIRAppCheckErrorCodeServerUnreachable);
  XCTAssertEqualObjects(requestPromise.error.userInfo[NSUnderlyingErrorKey], networkError);

  OCMVerifyAll(self.mockURLSession);
}

- (void)testDataRequestNot2xxHTTPStatusCode {
  NSURL *URL = [NSURL URLWithString:@"https://some.url.com"];
  NSData *requestBody = [@"Request body" dataUsingEncoding:NSUTF8StringEncoding];
  NSString *responseBodyString = @"Token verification failed.";

  NSData *HTTPResponseBody = [responseBodyString dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *HTTPResponse = [FIRURLSessionOCMockStub HTTPResponseWithCode:300];
  [self stubURLSessionDataTaskPromiseWithResponse:HTTPResponse
                                             body:HTTPResponseBody
                                            error:nil
                                   URLSessionMock:self.mockURLSession
                           requestValidationBlock:nil];

  // 2. Send request.
  __auto_type requestPromise = [self.APIService sendRequestWithURL:URL
                                                        HTTPMethod:@"POST"
                                                              body:requestBody
                                                 additionalHeaders:nil];

  // 3. Verify.
  XCTAssert(FBLWaitForPromisesWithTimeout(1));

  XCTAssertTrue(requestPromise.isRejected);
  XCTAssertNil(requestPromise.value);

  XCTAssertNotNil(requestPromise.error);
  XCTAssertEqualObjects(requestPromise.error.domain, FIRAppCheckErrorDomain);
  XCTAssertEqual(requestPromise.error.code, FIRAppCheckErrorCodeUnknown);

  // Expect response body and HTTP status code to be included in the error.
  NSString *failureReason = requestPromise.error.userInfo[NSLocalizedFailureReasonErrorKey];
  XCTAssertNotNil(failureReason);
  XCTAssertTrue([failureReason containsString:@"300"]);
  XCTAssertTrue([failureReason containsString:responseBodyString]);

  OCMVerifyAll(self.mockURLSession);
}

#pragma mark - Token Exchange API response

- (void)testAppCheckTokenWithAPIResponseValidResponse {
  // 1. Prepare input parameters.
  NSData *responseBody =
      [FIRFixtureLoader loadFixtureNamed:@"FACTokenExchangeResponseSuccess.json"];
  XCTAssertNotNil(responseBody);
  NSHTTPURLResponse *HTTPResponse = [FIRURLSessionOCMockStub HTTPResponseWithCode:200];
  GULURLSessionDataResponse *APIResponse =
      [[GULURLSessionDataResponse alloc] initWithResponse:HTTPResponse HTTPBody:responseBody];

  // 2. Expected result.
  NSString *expectedFACToken = @"valid_app_check_token";

  // 3. Parse API response.
  __auto_type tokenPromise = [self.APIService appCheckTokenWithAPIResponse:APIResponse];

  // 4. Verify.
  XCTAssert(FBLWaitForPromisesWithTimeout(1));

  XCTAssertTrue(tokenPromise.isFulfilled);
  XCTAssertNil(tokenPromise.error);

  XCTAssertEqualObjects(tokenPromise.value.token, expectedFACToken);
  XCTAssertTrue([FIRDateTestUtils isDate:tokenPromise.value.expirationDate
      approximatelyEqualCurrentPlusTimeInterval:1800
                                      precision:10]);
}

- (void)testAppCheckTokenWithAPIResponseInvalidFormat {
  // 1. Prepare input parameters.
  NSString *responseBodyString = @"Token verification failed.";
  NSData *responseBody = [responseBodyString dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *HTTPResponse = [FIRURLSessionOCMockStub HTTPResponseWithCode:200];
  GULURLSessionDataResponse *APIResponse =
      [[GULURLSessionDataResponse alloc] initWithResponse:HTTPResponse HTTPBody:responseBody];

  // 2. Parse API response.
  __auto_type tokenPromise = [self.APIService appCheckTokenWithAPIResponse:APIResponse];

  // 3. Verify.
  XCTAssert(FBLWaitForPromisesWithTimeout(1));

  XCTAssertTrue(tokenPromise.isRejected);
  XCTAssertNil(tokenPromise.value);

  XCTAssertNotNil(tokenPromise.error);
  XCTAssertEqualObjects(tokenPromise.error.domain, FIRAppCheckErrorDomain);
  XCTAssertEqual(tokenPromise.error.code, FIRAppCheckErrorCodeUnknown);

  // Expect response body and HTTP status code to be included in the error.
  NSString *failureReason = tokenPromise.error.userInfo[NSLocalizedFailureReasonErrorKey];
  XCTAssertEqualObjects(failureReason, @"JSON serialization error.");
}

- (void)testAppCheckTokenResponseMissingFields {
  [self assertMissingFieldErrorWithFixture:@"DeviceCheckResponseMissingToken.json"
                              missingField:@"token"];
  [self assertMissingFieldErrorWithFixture:@"DeviceCheckResponseMissingTimeToLive.json"
                              missingField:@"ttl"];
}

- (void)assertMissingFieldErrorWithFixture:(NSString *)fixtureName
                              missingField:(NSString *)fieldName {
  // 1. Parse API response.
  NSData *missingFiledBody = [FIRFixtureLoader loadFixtureNamed:fixtureName];
  XCTAssertNotNil(missingFiledBody);

  NSHTTPURLResponse *HTTPResponse = [FIRURLSessionOCMockStub HTTPResponseWithCode:200];
  GULURLSessionDataResponse *APIResponse =
      [[GULURLSessionDataResponse alloc] initWithResponse:HTTPResponse HTTPBody:missingFiledBody];

  // 2. Parse API response.
  __auto_type tokenPromise = [self.APIService appCheckTokenWithAPIResponse:APIResponse];

  // 3. Verify.
  XCTAssert(FBLWaitForPromisesWithTimeout(1));

  XCTAssertTrue(tokenPromise.isRejected);
  XCTAssertNil(tokenPromise.value);

  XCTAssertNotNil(tokenPromise.error);
  XCTAssertEqualObjects(tokenPromise.error.domain, FIRAppCheckErrorDomain);
  XCTAssertEqual(tokenPromise.error.code, FIRAppCheckErrorCodeUnknown);

  // Expect missing field name to be included in the error.
  NSString *failureReason = tokenPromise.error.userInfo[NSLocalizedFailureReasonErrorKey];
  NSString *fieldNameString = [NSString stringWithFormat:@"`%@`", fieldName];
  XCTAssertTrue([failureReason containsString:fieldNameString],
                @"Fixture `%@`: expected missing field %@ error not found", fixtureName,
                fieldNameString);
}

#pragma mark - Helpers

- (void)assertDataRequestSuccessWhenSendingHeartbeatsPayload:
    (nullable FIRHeartbeatsPayload *)heartbeatsPayload {
  NSURL *URL = [NSURL URLWithString:@"https://some.url.com"];
  NSDictionary *additionalHeaders = @{@"header1" : @"value1"};
  NSData *requestBody = [@"Request body" dataUsingEncoding:NSUTF8StringEncoding];

  // 1. Stub URL session.
  FIRRequestValidationBlock requestValidation = ^BOOL(NSURLRequest *request) {
    XCTAssertEqualObjects(request.URL, URL);

    NSMutableDictionary<NSString *, NSString *> *expectedHTTPHeaderFields = @{
      @"X-Goog-Api-Key" : self.APIKey,
      @"X-Ios-Bundle-Identifier" : [[NSBundle mainBundle] bundleIdentifier],
      @"header1" : @"value1",
    }
                                                                                .mutableCopy;

    NSString *_Nullable heartbeatHeaderValue =
        FIRHeaderValueFromHeartbeatsPayload(heartbeatsPayload);
    if (heartbeatHeaderValue) {
      expectedHTTPHeaderFields[@"X-firebase-client"] = heartbeatHeaderValue;
    }

    XCTAssertEqualObjects(request.allHTTPHeaderFields, expectedHTTPHeaderFields);

    XCTAssertEqualObjects(request.HTTPMethod, @"POST");
    XCTAssertEqualObjects(request.HTTPBody, requestBody);

    return YES;
  };

  NSData *HTTPResponseBody = [@"A response" dataUsingEncoding:NSUTF8StringEncoding];
  NSHTTPURLResponse *HTTPResponse = [FIRURLSessionOCMockStub HTTPResponseWithCode:200];
  [self stubURLSessionDataTaskPromiseWithResponse:HTTPResponse
                                             body:HTTPResponseBody
                                            error:nil
                                   URLSessionMock:self.mockURLSession
                           requestValidationBlock:requestValidation];

  // 2. Send request.
  __auto_type requestPromise = [self.APIService sendRequestWithURL:URL
                                                        HTTPMethod:@"POST"
                                                              body:requestBody
                                                 additionalHeaders:additionalHeaders];

  // 3. Verify.
  XCTAssert(FBLWaitForPromisesWithTimeout(1));

  XCTAssertTrue(requestPromise.isFulfilled);
  XCTAssertNil(requestPromise.error);

  XCTAssertEqualObjects(requestPromise.value.HTTPResponse, HTTPResponse);
  XCTAssertEqualObjects(requestPromise.value.HTTPBody, HTTPResponseBody);

  OCMVerifyAll(self.mockURLSession);
}

- (void)stubURLSessionDataTaskPromiseWithResponse:(NSHTTPURLResponse *)HTTPResponse
                                             body:(NSData *)body
                                            error:(NSError *)error
                                   URLSessionMock:(id)URLSessionMock
                           requestValidationBlock:
                               (FIRRequestValidationBlock)requestValidationBlock {
  // Validate request content.
  FIRRequestValidationBlock nonOptionalRequestValidationBlock =
      requestValidationBlock ?: ^BOOL(id request) {
        return YES;
      };

  id URLRequestValidationArg = [OCMArg checkWithBlock:nonOptionalRequestValidationBlock];

  // Result promise.
  FBLPromise<GULURLSessionDataResponse *> *result = [FBLPromise pendingPromise];
  if (error == nil) {
    GULURLSessionDataResponse *response =
        [[GULURLSessionDataResponse alloc] initWithResponse:HTTPResponse HTTPBody:body];
    [result fulfill:response];
  } else {
    [result reject:error];
  }

  // Stub the method.
  OCMExpect([URLSessionMock gul_dataTaskPromiseWithRequest:URLRequestValidationArg])
      .andReturn(result);
}

@end
