// -*- Mode: ObjC; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4; fill-column: 100 -*-
/*
 * Copyright the Collabora Online contributors.
 *
 * SPDX-License-Identifier: MPL-2.0
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#import "config.h"

#import <cstdio>
#import <string>
#import <vector>

#import <objc/message.h>
#import <objc/runtime.h>

#import <poll.h>
#import <sys/stat.h>

#import "ios.h"
#import "FakeSocket.hpp"
#import "COOLWSD.hpp"
#import "Log.hpp"
#import "MobileApp.hpp"
#import "SigUtil.hpp"
#import "Util.hpp"
#import "Clipboard.hpp"

#import "DocumentViewController.h"
#import "MainViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Poco/MemoryStream.h>

@interface DocumentViewController() <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply> {
    int closeNotificationPipeForForwardingThread[2];
    NSURL *downloadAsTmpURL;
}

@end

@implementation DocumentViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *userContentController = [[WKUserContentController alloc] init];

    [userContentController addScriptMessageHandler:self name:@"debug"];
    [userContentController addScriptMessageHandler:self name:@"lok"];
    [userContentController addScriptMessageHandler:self name:@"error"];
    [userContentController addScriptMessageHandlerWithReply:self contentWorld:[WKContentWorld pageWorld] name:@"clipboard"];

    configuration.userContentController = userContentController;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.allowsLinkPreview = NO;

    // Prevent the WebView from scrolling. Sadly I couldn't figure out how to do it in the JS,
    // so the problem is still there when using Online from Mobile Safari.
    // self.webView.scrollView.scrollEnabled = NO;

    // Reenable debugging from Safari
    // The new WKWebView.inspectable property must be set to YES in order
    // for Safari to connect to a debug version of the iOS app whether the
    // app is running on an iOS device or on macOS.
    if (@available(macOS 13.3, iOS 16.4, tvOS 16.4, *)) {
#if ENABLE_DEBUG == 1
        self.webView.inspectable = YES;
#else
        self.webView.inspectable = NO;
#endif
    }

    // Prevent the user from zooming the WebView by assigning ourselves as the delegate, and
    // stopping any zoom attempt in scrollViewWillBeginZooming: below. (The zooming of the document
    // contents is handled fully in JavaScript, the WebView has no knowledge of that.)
    // self.webView.scrollView.delegate = self;

    [self.view addSubview:self.webView];

    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;

    // Hack for tdf#129380: Don't show the "shortcut bar" if a hardware keyboard is used.

    WKWebView *webViewP = self.webView;
    NSDictionary *views = NSDictionaryOfVariableBindings(webViewP);
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-0-[webViewP(>=0)]-0-|"
                                                                      options:0
                                                                      metrics:nil
                                                                        views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-0-[webViewP(>=0)]-0-|"
                                                                      options:0
                                                                      metrics:nil
                                                                        views:views]];
}

- (void)viewWillAppear {
    [super viewWillAppear];

    // When the user uses the camer to insert a photo, when the camera is displayed, this view is
    // removed. After the photo is taken it is then added back to the hierarchy. Our Document object
    // is still there intact, however, so no need to re-open the document when we re-appear.

    // Check whether the Document object is an already initialised one.
    if (self.document && self.document->fakeClientFd >= 0)
        return;

    NSError* error;
    if(![self.document loadInBrowser:error]) {
        NSLog(@"OPENING DOCUMENT ERROR: %@", error.localizedDescription);
    }
}

- (IBAction)dismissDocumentViewController {
    NSLog(@"BYE");
    [self.document close];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"debug"];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"lok"];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"error"];
    // Don't set webView.configuration.userContentController to
    // nil as it generates a "nil not allowed" compiler warning
    [self.webView removeFromSuperview];
    self.webView = nil;
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
    MainViewController *mainController = [storyBoard instantiateControllerWithIdentifier:@"MainViewController"];
    ((NSWindowController* ) self.view.window).contentViewController = mainController;
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    LOG_TRC("didCommitNavigation: " << [[navigation description] UTF8String]);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    LOG_TRC("didFailNavigation: " << [[navigation description] UTF8String]);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    LOG_TRC("didFailProvisionalNavigation: " << [[navigation description] UTF8String]);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    LOG_TRC("didFinishNavigation: " << [[navigation description] UTF8String]);
}

- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation {
    LOG_TRC("didReceiveServerRedirectForProvisionalNavigation: " << [[navigation description] UTF8String]);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    LOG_TRC("didStartProvisionalNavigation: " << [[navigation description] UTF8String]);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    LOG_TRC("decidePolicyForNavigationAction: " << [[navigationAction description] UTF8String]);
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    LOG_TRC("decidePolicyForNavigationResponse: " << [[navigationResponse description] UTF8String]);
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    LOG_TRC("createWebViewWithConfiguration");
    return webView;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    LOG_TRC("runJavaScriptAlertPanelWithMessage: " << [message UTF8String]);
    //    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@""
    //                                                    message:message
    //                                                   delegate:nil
    //                                          cancelButtonTitle:nil
    //                                          otherButtonTitles:@"OK", nil];
    //    [alert show];
    completionHandler();
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL result))completionHandler {
    LOG_TRC("runJavaScriptConfirmPanelWithMessage: " << [message UTF8String]);
    completionHandler(YES);
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *result))completionHandler {
    LOG_TRC("runJavaScriptTextInputPanelWithPrompt: " << [prompt UTF8String]);
    completionHandler(@"Something happened.");
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    // Fix issue #5876 by closing the document if the content process dies
    [self bye];
    LOG_ERR("WebContent process terminated! Is closing the document enough?");
}

// This is the same method as Java_org_libreoffice_androidlib_LOActivity_getClipboardContent, with minimal editing to work with objective C
- (bool)getClipboardContent:(out NSMutableDictionary *)content {
    const char** mimeTypes = nullptr;
    size_t outCount = 0;
    char  **outMimeTypes = nullptr;
    size_t *outSizes = nullptr;
    char  **outStreams = nullptr;
    bool bResult = false;

    if (DocumentData::get(self.document->appDocId).loKitDocument->getClipboard(mimeTypes,
                                                     &outCount, &outMimeTypes,
                                                     &outSizes, &outStreams))
    {
        // return early
        if (outCount == 0)
            return bResult;

        for (size_t i = 0; i < outCount; ++i)
        {
            NSString * identifier = [NSString stringWithUTF8String:outMimeTypes[i]];

            // For interop with other apps, if this mime-type is known we can export it
            UTType * uti = [UTType typeWithMIMEType:identifier];
            if (uti != nil && !uti.dynamic) {
                if ([uti conformsToType:UTTypePlainText]) {
                    [content setValue:outStreams[i] == NULL ? @"" : [NSString stringWithUTF8String:outStreams[i]] forKey:uti.identifier];
                } else if (uti != nil && [uti conformsToType:UTTypeImage]) {
                    NSImage* image = [[NSImage alloc] initWithData: [NSData dataWithBytes:outStreams[i] length:outSizes[i]]];
                    [content setValue:image forKey:uti.identifier];
                } else {
                    [content setValue:[NSData dataWithBytes:outStreams[i] length:outSizes[i]] forKey:uti.identifier];
                }
            }
            
            // But to preserve the data we need, we'll always also export the raw, unaltered bytes
            [content setValue:[NSData dataWithBytes:outStreams[i] length:outSizes[i]] forKey:identifier];
        }
        bResult = true;
    }
    else
        LOG_DBG("failed to fetch mime-types");

    const char* mimeTypesHTML[] = { "text/plain;charset=utf-8", "text/html", nullptr };

    if (DocumentData::get(self.document->appDocId).loKitDocument->getClipboard(mimeTypesHTML,
                                                     &outCount, &outMimeTypes,
                                                     &outSizes, &outStreams))
    {
        // return early
        if (outCount == 0)
            return bResult;

        for (size_t i = 0; i < outCount; ++i)
        {
            NSString * identifier = [NSString stringWithUTF8String:outMimeTypes[i]];

            // For interop with other apps, if this mime-type is known we can export it
            UTType * uti = [UTType typeWithMIMEType:identifier];
            if (uti != nil && !uti.dynamic) {
                if ([uti conformsToType:UTTypePlainText]) {
                    [content setValue:outStreams[i] == NULL ? @"" : [NSString stringWithUTF8String:outStreams[i]] forKey:uti.identifier];
                } else if (uti != nil && [uti conformsToType:UTTypeImage]) {
                    NSImage* image = [[NSImage alloc] initWithData: [NSData dataWithBytes:outStreams[i] length:outSizes[i]]];
                    [content setValue:image forKey:uti.identifier];
                } else {
                    [content setValue:[NSData dataWithBytes:outStreams[i] length:outSizes[i]] forKey:uti.identifier];
                }
            }
            
            // But to preserve the data we need, we'll always also export the raw, unaltered bytes
            [content setValue:[NSData dataWithBytes:outStreams[i] length:outSizes[i]] forKey:identifier];
        }
        bResult = true;
    }
    else
        LOG_DBG("failed to fetch mime-types");

    return bResult;
}

- (void)setClipboardContent:(NSPasteboard *)pasteboard {
    NSMutableDictionary * pasteboardItems = [NSMutableDictionary new];
    
    if (pasteboard.pasteboardItems.count != 0) {
        for (NSPasteboardItem * item in pasteboard.pasteboardItems)
        {
            
            if (![item.types containsObject:NSPasteboardTypeString]) {
                LOG_WRN("Pasteboard item did not have associated mime type when deserializing clipboard, skipping...");
                continue;
            }
            
            NSData * value = [item dataForType:NSPasteboardTypeString];
            if (value != nil) {
                [pasteboardItems setObject:value forKey:@"text/plain"];
            }
        }
    }
    
    const char * pInMimeTypes[pasteboardItems.count];
    size_t pInSizes[pasteboardItems.count];
    const char * pInStreams[pasteboardItems.count];
    
    size_t i = 0;
    
    for (NSString * mime in pasteboardItems) {
        pInMimeTypes[i] = [mime UTF8String];
        pInStreams[i] = (const char*)[pasteboardItems[mime] bytes];
        pInSizes[i] = [pasteboardItems[mime] length];
        i++;
    }
    
    DocumentData::get(self.document->appDocId).loKitDocument->setClipboard(pasteboardItems.count, pInMimeTypes, pInSizes, pInStreams);
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message replyHandler:(nonnull void (^)(id _Nullable, NSString * _Nullable))replyHandler {

    if ([message.name isEqualToString:@"clipboard"]) {
        if ([message.body isEqualToString:@"read"]) {
            NSPasteboard * pasteboard = [NSPasteboard generalPasteboard];
            
            [self setClipboardContent:pasteboard];
            
            replyHandler(@"(internal)", nil);
        } else if ([message.body isEqualToString:@"write"]) {
            NSMutableDictionary * pasteboardItem = [NSMutableDictionary dictionaryWithCapacity:2];
            bool success = [self getClipboardContent:pasteboardItem];
            
            if (!success) {
                replyHandler(nil, @"Failed to get clipboard contents...");
                return;
            }
            
            // NSPasteboard * pasteboard = [NSPasteboard generalPasteboard];
            // [pasteboard setItems:[NSArray arrayWithObject:pasteboardItem]];
            
            replyHandler(nil, nil);
        } else if ([message.body hasPrefix:@"sendToInternal "]) {
            ClipboardData data;
            NSString * content = [message.body substringFromIndex:[@"sendToInternal " length]];
            std::vector<char> html;
            
            size_t nInCount;
            
            if ([content hasPrefix:@"<!DOCTYPE html>"]) {
                // Content is just HTML
                const char * _Nullable content_cstr = [content cStringUsingEncoding:NSUTF8StringEncoding];
                html = std::vector(content_cstr, content_cstr + [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
                nInCount = 1;
            } else {
                Poco::MemoryInputStream stream([content cStringUsingEncoding:NSUTF8StringEncoding], [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
                data.read(stream);
                nInCount = data.size();
            }
            
            std::vector<size_t> pInSizes(nInCount);
            std::vector<const char*> pInMimeTypes(nInCount);
            std::vector<const char*> pInStreams(nInCount);
            
            if (html.empty()) {
                for (size_t i = 0; i < nInCount; ++i) {
                    pInSizes[i] = data._content[i].length();
                    pInStreams[i] = data._content[i].c_str();
                    pInMimeTypes[i] = data._mimeTypes[i].c_str();
                }
            } else {
                pInSizes[0] = html.size();
                pInStreams[0] = html.data();
                pInMimeTypes[0] = "text/html";
            }
            
            if (!DocumentData::get(self.document->appDocId).loKitDocument->setClipboard(nInCount, pInMimeTypes.data(), pInSizes.data(),
                                                                                        pInStreams.data())) {
                LOG_ERR("set clipboard returned failure");
                replyHandler(nil, @"set clipboard returned failure");
            } else {
                LOG_TRC("set clipboard succeeded");
                replyHandler(nil, nil);
            }
        } else {
            replyHandler(nil, [NSString stringWithFormat:@"Invalid clipboard action %@", message.body]);
        }
    } else {
        LOG_ERR("Unrecognized kind of message received from WebView: " << [message.name UTF8String] << ":" << [message.body UTF8String]);
        replyHandler(nil, [NSString stringWithFormat:@"Message of type %@ does not exist or is not replyable", message.name]);
    }
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    int rc;
    struct pollfd p;

    if ([message.name isEqualToString:@"error"]) {
        LOG_ERR("Error from WebView: " << [message.body UTF8String]);
    } else if ([message.name isEqualToString:@"debug"]) {
        std::cerr << "==> " << [message.body UTF8String] << std::endl;
    } else if ([message.name isEqualToString:@"lok"]) {
        NSString *subBody = [message.body substringToIndex:std::min(100ul, ((NSString*)message.body).length)];
        if (subBody.length < ((NSString*)message.body).length)
            subBody = [subBody stringByAppendingString:@"..."];

        LOG_DBG("To Online: " << [subBody UTF8String]);

#if 0
        static int n = 0;

        if ((n++ % 10) == 0) {
            auto enumerator = [[NSFileManager defaultManager] enumeratorAtPath:NSHomeDirectory()];
            NSString *file;
            long long total = 0;
            while ((file = [enumerator nextObject])) {
                if ([enumerator fileAttributes][NSFileType] == NSFileTypeRegular)
                    total += [[enumerator fileAttributes][NSFileSize] longLongValue];
            }
            NSLog(@"==== Total size of app home directory: %lld", total);
        }
#endif

        if ([message.body isEqualToString:@"HULLO"]) {
            // Now we know that the JS has started completely

            // Contact the permanently (during app lifetime) listening COOLWSD server
            // "public" socket
            assert(coolwsd_server_socket_fd != -1);
            rc = fakeSocketConnect(self.document->fakeClientFd, coolwsd_server_socket_fd);
            assert(rc != -1);

            // Create a socket pair to notify the below thread when the document has been closed
            fakeSocketPipe2(closeNotificationPipeForForwardingThread);

            // Start another thread to read responses and forward them to the JavaScript
            dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                           ^{
                               Util::setThreadName("app2js");
                               while (true) {
                                   struct pollfd p[2];
                                   p[0].fd = self.document->fakeClientFd;
                                   p[0].events = POLLIN;
                                   p[1].fd = self->closeNotificationPipeForForwardingThread[1];
                                   p[1].events = POLLIN;
                                   if (fakeSocketPoll(p, 2, -1) > 0) {
                                       if (p[1].revents == POLLIN) {
                                           // The code below handling the "BYE" fake Websocket
                                           // message has closed the other end of the
                                           // closeNotificationPipeForForwardingThread. Let's close
                                           // the other end too just for cleanliness, even if a
                                           // FakeSocket as such is not a system resource so nothing
                                           // is saved by closing it.
                                           fakeSocketClose(self->closeNotificationPipeForForwardingThread[1]);

                                           // Close our end of the fake socket connection to the
                                           // ClientSession thread, so that it terminates
                                           fakeSocketClose(self.document->fakeClientFd);

                                           return;
                                       }
                                       if (p[0].revents == POLLIN) {
                                           int n = fakeSocketAvailableDataLength(self.document->fakeClientFd);
                                           // I don't want to check for n being -1 here, even if
                                           // that will lead to a crash (std::length_error from the
                                           // below std::vector constructor), as n being -1 is a
                                           // sign of something being wrong elsewhere anyway, and I
                                           // prefer to fix the root cause. Let's see how well this
                                           // works out. See tdf#122543 for such a case.
                                           if (n == 0)
                                               return;
                                           std::vector<char> buf(n);
                                           n = fakeSocketRead(self.document->fakeClientFd, buf.data(), n);
                                           [self.document send2JS:buf.data() length:n];
                                       }
                                   }
                                   else
                                       break;
                               }
                               assert(false);
                           });

            // First we simply send the Online C++ parts the URL and the appDocId. This corresponds
            // to the GET request with Upgrade to WebSocket.
            std::string url([[self.document->copyFileURL absoluteString] UTF8String]);
            p.fd = self.document->fakeClientFd;
            p.events = POLLOUT;
            fakeSocketPoll(&p, 1, -1);

            // This is read in the iOS-specific code in ClientRequestDispatcher::handleIncomingMessage() in COOLWSD.cpp
            std::string message(url + " " + std::to_string(self.document->appDocId));
            fakeSocketWrite(self.document->fakeClientFd, message.c_str(), message.size());

            return;
        } else if ([message.body isEqualToString:@"BYE"]) {
            LOG_TRC("Document window terminating on JavaScript side. Closing our end of the socket.");

            [self bye];
            return;
        } else if ([message.body isEqualToString:@"SLIDESHOW"]) {

            // Create the SVG for the slideshow.

            self.slideshowFile = FileUtil::createRandomTmpDir() + "/slideshow.svg";
            self.slideshowURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:self.slideshowFile.c_str()] isDirectory:NO];

            DocumentData::get(self.document->appDocId).loKitDocument->saveAs([[self.slideshowURL absoluteString] UTF8String], "svg", nullptr);

            // Add a new full-screen WebView displaying the slideshow.

            WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
            WKUserContentController *userContentController = [[WKUserContentController alloc] init];

            [userContentController addScriptMessageHandler:self name:@"lok"];

            configuration.userContentController = userContentController;

            self.slideshowWebView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];

            [self.slideshowWebView becomeFirstResponder];

            // self.slideshowWebView.contentMode = UIViewContentModeScaleAspectFit;
            self.slideshowWebView.translatesAutoresizingMaskIntoConstraints = NO;
            self.slideshowWebView.navigationDelegate = self;
            self.slideshowWebView.UIDelegate = self;

            self.webView.hidden = true;

            [self.view addSubview:self.slideshowWebView];

            WKWebView *slideshowWebViewP = self.slideshowWebView;
            NSDictionary *views = NSDictionaryOfVariableBindings(slideshowWebViewP);
            [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-0-[slideshowWebViewP(>=0)]-0-|"
                                                                              options:0
                                                                              metrics:nil
                                                                                views:views]];
            [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-0-[slideshowWebViewP(>=0)]-0-|"
                                                                              options:0
                                                                              metrics:nil
                                                                                views:views]];
            [self.slideshowWebView loadRequest:[NSURLRequest requestWithURL:self.slideshowURL]];

            return;
        } else if ([message.body isEqualToString:@"EXITSLIDESHOW"]) {

            std::remove(self.slideshowFile.c_str());

            [self.slideshowWebView removeFromSuperview];
            self.slideshowWebView = nil;
            self.webView.hidden = false;

            return;
        } else if ([message.body isEqualToString:@"PRINT"]) {

            // Create the PDF to print.

            std::string printFile = FileUtil::createRandomTmpDir() + "/print.pdf";
            NSURL *printURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:printFile.c_str()] isDirectory:NO];
            DocumentData::get(self.document->appDocId).loKitDocument->saveAs([[printURL absoluteString] UTF8String], "pdf", nullptr);
            NSLog(@"IRM: Print %@", printURL.absoluteString);
            /*
            
            NSPrintInfo *printInfo = [NSPrintInfo sharedPrintInfo];
            printInfo.orientation = NSPaperOrientationPortrait; // FIXME Check the document?
            printInfo.paperName = @"Document"; // FIXME

            NSPrintOperation* printOperation = [NSPrintOperation printOperationWithView:self.view printInfo:printInfo];


            [pic presentFromRect:CGRectZero
                          inView:self.webView
                        animated:YES
               completionHandler:^(UIPrintInteractionController *pic, BOOL completed, NSError *error) {
                    LOG_TRC("print completion handler gets " << (completed?"YES":"NO"));
                    std::remove(printFile.c_str());
                }];
             */

            return;
        } else if ([message.body isEqualToString:@"FOCUSIFHWKBD"]) {
            NSString *hwKeyboardMagic = @"{"
            "    if (window.MagicToGetHWKeyboardWorking) {"
            "        window.MagicToGetHWKeyboardWorking();"
            "    }"
            "}";
            [self.webView evaluateJavaScript:hwKeyboardMagic
                           completionHandler:^(id _Nullable obj, NSError * _Nullable error)
             {
                if (error) {
                    LOG_ERR("Error after " << [hwKeyboardMagic UTF8String] << ": " << [[error localizedDescription] UTF8String]);
                    NSString *jsException = error.userInfo[@"WKJavaScriptExceptionMessage"];
                    if (jsException != nil)
                        LOG_ERR("JavaScript exception: " << [jsException UTF8String]);
                }
            }
            ];
            return;
        } else if ([message.body hasPrefix:@"HYPERLINK"]) {
            NSArray *messageBodyItems = [message.body componentsSeparatedByString:@" "];
            if ([messageBodyItems count] >= 2) {
                NSURL *url = [[NSURL alloc] initWithString:messageBodyItems[1]];
                [[NSWorkspace sharedWorkspace] openURL:url];
                return;
            }
        } else if ([message.body isEqualToString:@"FONTPICKER"]) {
            /*
            UIFontPickerViewControllerConfiguration *configuration = [[UIFontPickerViewControllerConfiguration alloc] init];
            configuration.includeFaces = YES;
            UIFontPickerViewController *picker = [[UIFontPickerViewController alloc] initWithConfiguration:configuration];
            picker.delegate = self;
            [self presentViewController:picker
                               animated:YES
                             completion:nil];
             */
            return;
        } else if ([message.body hasPrefix:@"downloadas "]) {
            NSArray<NSString*> *messageBodyItems = [message.body componentsSeparatedByString:@" "];
            NSString *format = nil;
            if ([messageBodyItems count] >= 2) {
                for (int i = 1; i < [messageBodyItems count]; i++) {
                    if ([messageBodyItems[i] hasPrefix:@"format="])
                        format = [messageBodyItems[i] substringFromIndex:[@"format=" length]];
                }

                if (format == nil)
                    return;     // Warn?

                // Handle special "direct-" formats
                NSRange range = [format rangeOfString:@"direct-"];
                if (range.location == 0)
                    format = [format substringFromIndex:range.length];

                // First save it in the requested format to a temporary location. First remove any
                // leftover identically named temporary file.

                NSURL *tmpFileDirectory = [[NSFileManager.defaultManager temporaryDirectory] URLByAppendingPathComponent:@"export"];
                if (![NSFileManager.defaultManager createDirectoryAtURL:tmpFileDirectory withIntermediateDirectories:YES attributes:nil error:nil]) {
                    LOG_ERR("Could not create directory " << [[tmpFileDirectory path] UTF8String]);
                    return;
                }
                NSString *tmpFileName = [[[self.document->copyFileURL lastPathComponent] stringByDeletingPathExtension] stringByAppendingString:[@"." stringByAppendingString:format]];
                downloadAsTmpURL = [tmpFileDirectory URLByAppendingPathComponent:tmpFileName];

                std::remove([[downloadAsTmpURL path] UTF8String]);

                DocumentData::get(self.document->appDocId).loKitDocument->saveAs([[downloadAsTmpURL absoluteString] UTF8String], [format UTF8String], nullptr);

                // Then verify that it indeed was saved, and then use an
                // UIDocumentPickerViewController to ask the user where to store the exported
                // document.

                struct stat statBuf;
                if (stat([[downloadAsTmpURL path] UTF8String], &statBuf) == -1) {
                    LOG_ERR("Could apparently not save to '" <<  [[downloadAsTmpURL path] UTF8String] << "'");
                    return;
                }
                /*
                UIDocumentPickerViewController *picker =
                    [[UIDocumentPickerViewController alloc] initForExportingURLs:[NSArray arrayWithObject:downloadAsTmpURL] asCopy:YES];
                picker.delegate = self;
                [self presentViewController:picker
                                   animated:YES
                                 completion:nil];
                 */
                return;
            }
        }

        const char *buf = [message.body UTF8String];
        p.fd = self.document->fakeClientFd;
        p.events = POLLOUT;
        fakeSocketPoll(&p, 1, -1);
        fakeSocketWrite(self.document->fakeClientFd, buf, strlen(buf));
    } else {
        LOG_ERR("Unrecognized kind of message received from WebView: " << [message.name UTF8String] << ":" << [message.body UTF8String]);
    }
}

/*
- (void)fontPickerViewControllerDidPickFont:(UIFontPickerViewController *)viewController {
    // Partial fix #5885 Close the font picker when a font is tapped
    // This matches the behavior of Apple apps such as Pages and Mail.
    [viewController dismissViewControllerAnimated:YES completion:nil];

    // NSLog(@"Picked font: %@", [viewController selectedFontDescriptor]);
    NSDictionary<UIFontDescriptorAttributeName, id> *attribs = [[viewController selectedFontDescriptor] fontAttributes];
    NSString *family = attribs[UIFontDescriptorFamilyAttribute];
    if (family && [family length] > 0) {
        NSString *js = [[@"window.MagicFontNameCallback('" stringByAppendingString:family] stringByAppendingString:@"');"];
        [self.webView evaluateJavaScript:js
                       completionHandler:^(id _Nullable obj, NSError * _Nullable error)
             {
                 if (error) {
                     LOG_ERR("Error after " << [js UTF8String] << ": " << [[error localizedDescription] UTF8String]);
                     NSString *jsException = error.userInfo[@"WKJavaScriptExceptionMessage"];
                     if (jsException != nil)
                         LOG_ERR("JavaScript exception: " << [jsException UTF8String]);
                 }
             }
         ];
    }
}
 */

- (void)bye {
    // Close one end of the socket pair, that will wake up the forwarding thread above
    fakeSocketClose(closeNotificationPipeForForwardingThread[0]);

    // DocumentData::deallocate(self.document->appDocId);

    if (![[NSFileManager defaultManager] removeItemAtURL:self.document->copyFileURL error:nil]) {
        LOG_SYS("Could not remove copy of document at " << [[self.document->copyFileURL path] UTF8String]);
    }

    // The dismissViewControllerAnimated must be done on the main queue.
    dispatch_async(dispatch_get_main_queue(),
                   ^{
                       [self dismissDocumentViewController];
                   });
}

- (void)exportFileURL:(NSURL *)fileURL {
    if (!fileURL || ![fileURL isFileURL])
        return;

    // Verify that a file was successfully exported
    BOOL bIsDir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path] isDirectory:&bIsDir] || bIsDir) {
        LOG_ERR("Could apparently not export '" << [[fileURL path] UTF8String] << "'");
        return;
    }

    downloadAsTmpURL = fileURL;

    // Use a UIDocumentPickerViewController to ask the user where to store
    // the exported document and, when the picker is dismissed, have the
    // picker delete the original file.
    /*
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:[NSArray arrayWithObject:fileURL] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
     */
}

@end

// vim:set shiftwidth=4 softtabstop=4 expandtab:
