#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NSURL *CentralYouTubeEmbedURL(NSURL *link);
UIViewController *CentralYouTubeSearch(NSURLSession *session, void (^selection)(NSURL *embedURL));

WKWebView *CentralYouTubePlayer(void);
void CentralYouTubeLoadPlayer(WKWebView *view, NSURL *embedURL, BOOL autoplay);
