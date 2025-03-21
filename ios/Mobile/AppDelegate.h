// -*- Mode: ObjC; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4; fill-column: 100 -*-
/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

#import <LibreOfficeKit/LibreOfficeKit.h>
#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (weak) NSWindow* window;

@end

extern NSString *app_locale;
extern NSString *app_text_direction;

// vim:set shiftwidth=4 softtabstop=4 expandtab:

