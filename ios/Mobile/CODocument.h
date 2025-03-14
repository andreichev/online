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

#import <string>
#import <Cocoa/Cocoa.h>

#define LOK_USE_UNSTABLE_API
#import <LibreOfficeKit/LibreOfficeKit.h>

@class DocumentViewController;

@interface CODocument : NSDocument {
@public
    int fakeClientFd;
    NSURL *copyFileURL;
    unsigned appDocId;
    bool readOnly;
}

@property (weak) DocumentViewController *viewController;

- (void)send2JS:(const char*)buffer length:(int)length;

- (BOOL)loadInBrowser: (NSError *)error;

@end

// vim:set shiftwidth=4 softtabstop=4 expandtab:
