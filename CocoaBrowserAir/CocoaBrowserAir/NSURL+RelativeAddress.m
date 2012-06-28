//
//  NSURL+RelativeAddress.m
//  Cocoa Browser Air
//
//  Created by numata on 09/08/31.
//  Copyright 2009 Satoshi Numata. All rights reserved.
//

#import "NSURL+RelativeAddress.h"


@implementation NSURL (RelativeAddress)

+ (id)numataURLWithString:(NSString *)URLString relativeToURL:(NSURL *)baseURL
{
    NSString *baseURLStr = [baseURL absoluteString];
    NSRange sharpRange = [baseURLStr rangeOfString:@"#" options:NSBackwardsSearch];
    if (sharpRange.location != NSNotFound) {
        baseURLStr = [baseURLStr substringToIndex:sharpRange.location];
    }
    
    if ([baseURLStr hasPrefix:@"file://localhost/"]) {
        baseURLStr = [@"file:///" stringByAppendingString:[baseURLStr substringFromIndex:17]];
    }
    
    NSString *basePath = [baseURLStr stringByDeletingLastPathComponent];
    NSString *theURLStr = [basePath stringByAppendingPathComponent:URLString];
    NSURL *theURL = [NSURL URLWithString:theURLStr];

    return theURL;
}

- (NSURL *)numataStandardizedURL
{
    NSString *urlStr = [self absoluteString];

    NSRange sharpRange = [urlStr rangeOfString:@"#" options:NSBackwardsSearch];
    if (sharpRange.location != NSNotFound) {
        urlStr = [urlStr substringToIndex:sharpRange.location];
    }
    
    if ([urlStr hasPrefix:@"file://localhost/"]) {
        urlStr = [@"file:///" stringByAppendingString:[urlStr substringFromIndex:17]];
    }

    return [NSURL URLWithString:urlStr];
}

@end



