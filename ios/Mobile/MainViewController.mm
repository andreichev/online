#import "MainViewController.h"

#import "DocumentViewController.h"

@implementation MainViewController

static DocumentViewController *newDocumentViewControllerFor(NSURL *url, bool readOnly) {
    NSStoryboard *storyBoard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
    DocumentViewController *documentViewController = [storyBoard instantiateControllerWithIdentifier:@"DocumentViewController"];
    documentViewController.document = [[CODocument alloc] initWithContentsOfURL:url ofType:@"" error:nil];
    documentViewController.document->fakeClientFd = -1;
    documentViewController.document->readOnly = readOnly;
    documentViewController.document.viewController = documentViewController;
    return documentViewController;
 }


- (IBAction)button:(id)sender {
    NSURL* url = [NSURL fileURLWithPath: [self.urlTextField stringValue]];
    NSLog(@"URL: %@", [url absoluteString]);
    
    DocumentViewController* controller = newDocumentViewControllerFor(url, false);
    ((NSWindowController* ) self.view.window).contentViewController = controller;
}

@end
