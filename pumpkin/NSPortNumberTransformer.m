#import "NSPortNumberTransformer.h"

NSString * const PortNumberTransformerName = @"PortNumberTransformer";

@implementation NSPortNumberTransformer

+(void)registerForPortBindings {
    [NSValueTransformer setValueTransformer:[[[NSPortNumberTransformer alloc] init] autorelease]
                                    forName:PortNumberTransformerName];
}

+(Class)transformedValueClass { return [NSNumber class]; }
+(BOOL)allowsReverseTransformation { return YES; }
-(id)transformedValue:(id)value {
    if(value==nil) return nil;
    if(![value respondsToSelector:@selector(integerValue)]) return nil;
    NSInteger rv = [value integerValue];
    if(rv<1 || rv>65535) return nil;
    return [NSString stringWithFormat:@"%ld",(long)rv];
}
-(id)reverseTransformedValue:(id)value {
    if(value==nil) return nil;
    if(![value respondsToSelector:@selector(integerValue)]) return nil;
    NSInteger rv = [value integerValue];
    if(rv<1 || rv>65535) return nil;
    return [NSNumber numberWithInteger:rv];
}

@end
