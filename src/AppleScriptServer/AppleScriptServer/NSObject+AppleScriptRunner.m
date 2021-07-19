#import "NSObject+AppleScriptRunner.h"
#import <OSAKit/OSAKit.h>

NSString *embeddedBase64JSON = @"eyJhc2stZm9yLWF1dG9tYXRpb24iOlsiQXBwbGVTY3JpcHQiLCJ0ZWxsIGFwcGxpY2F0aW9uIFwiTWVzc2FnZXNcIiB0byBzZXQgcyB0byBzZXJ2aWNlc1xuIl0sImNyZWF0ZS10aHJlYWQiOlsiQXBwbGVTY3JpcHQiLCJ0ZWxsIGFwcGxpY2F0aW9uIFwiTWVzc2FnZXNcIiB0byBzZXQgaW1zZ1NlcnZpY2UgdG8gMXN0IHNlcnZpY2Ugd2hvc2Ugc2VydmljZSB0eXBlID0gaU1lc3NhZ2VcbnRlbGwgYXBwbGljYXRpb24gXCJNZXNzYWdlc1wiIHRvIHNldCB0aHJlYWQgdG8gbWFrZSBuZXcgdGV4dCBjaGF0IHdpdGggcHJvcGVydGllcyB7cGFydGljaXBhbnRzOnskezF9fX1cbmdldCB0aHJlYWRcbiJdLCJoaWRlLW1lc3NhZ2VzLWJlaGluZC10ZXh0cyI6WyJBcHBsZVNjcmlwdCIsInRlbGwgYXBwbGljYXRpb24gXCJTeXN0ZW0gRXZlbnRzXCJcbnRlbGwgYXBwbGljYXRpb24gcHJvY2VzcyBcIiR7MH1cIiB0byBzZXQge3RleHRzU2l6ZSwgdGV4dHNQb3N9IHRvIHtzaXplLCBwb3NpdGlvbn0gb2Ygd2luZG93IDBcbnRlbGwgYXBwbGljYXRpb24gcHJvY2VzcyBcIk1lc3NhZ2VzXCIgdG8gdGVsbCB3aW5kb3cgMCB0byBzZXQge3NpemUsIHBvc2l0aW9ufSB0byB7dGV4dHNTaXplLCB0ZXh0c1Bvc31cbmVuZCB0ZWxsXG4iXSwiaGlkZS1tZXNzYWdlcyI6WyJBcHBsZVNjcmlwdCIsInRlbGwgYXBwbGljYXRpb24gXCJTeXN0ZW0gRXZlbnRzXCJcbnRlbGwgcHJvY2VzcyBcIk1lc3NhZ2VzXCIgdG8gc2V0IHZpc2libGUgdG8gZmFsc2VcbnRlbGwgYXBwbGljYXRpb24gXCJNZXNzYWdlc1wiIHRvIGNsb3NlIHdpbmRvdyAwXG5lbmQgdGVsbFxuIl0sIm1lc3NhZ2VzLXJ1bm5pbmciOlsiQXBwbGVTY3JpcHQiLCJnZXQgcnVubmluZyBvZiBhcHBsaWNhdGlvbiBcIk1lc3NhZ2VzXCJcbiJdLCJtZXNzYWdlcy12aXNpYmxlIjpbIkFwcGxlU2NyaXB0IiwidGVsbCBhcHBsaWNhdGlvbiBcIlN5c3RlbSBFdmVudHNcIiB0byBzZXQgYXBwVmlzaWJsZSB0byB2aXNpYmxlIG9mIHByb2Nlc3MgXCJNZXNzYWdlc1wiXG4iXSwic2VuZC1maWxlIjpbIkphdmFTY3JpcHQiLCJPYmpDLmltcG9ydCgnc3RkbGliJylcbnZhciBmbiA9IChmdW5jdGlvbiAodGlkLCBmcCwgaGFuZGxlKSB7XG4gIGNvbnN0IE1lc3NhZ2VzID0gQXBwbGljYXRpb24oJ01lc3NhZ2VzJylcbiAgbGV0IHRocmVhZFxuICB0cnkge1xuICAgIHRocmVhZCA9IE1lc3NhZ2VzLnRleHRDaGF0cy5ieUlkKHRpZCkoKVxuICB9IGNhdGNoIChlKSB7IH1cbiAgaWYgKCF0aHJlYWQpIHtcbiAgICB0cnkge1xuICAgICAgdGhyZWFkID0gTWVzc2FnZXMuYnVkZGllcy53aG9zZSh7IGhhbmRsZSB9KVswXVxuICAgIH0gY2F0Y2ggKGUpIHsgfVxuICB9XG4gIE1lc3NhZ2VzLnNlbmQoUGF0aChmcCksIHsgdG86IHRocmVhZCB9KVxufVxuKVxudmFyIGFyZ3MgPSAkezB9XG52YXIgb3V0ICA9IGZuLmFwcGx5KG51bGwsIGFyZ3MpIl0sInNlbmQtdGV4dCI6WyJKYXZhU2NyaXB0IiwiT2JqQy5pbXBvcnQoJ3N0ZGxpYicpXG52YXIgZm4gPSAoZnVuY3Rpb24gKHRpZCwgdHh0LCBoYW5kbGUpIHtcbiAgY29uc3QgTWVzc2FnZXMgPSBBcHBsaWNhdGlvbignTWVzc2FnZXMnKVxuICBsZXQgdGhyZWFkXG4gIHRyeSB7XG4gICAgdGhyZWFkID0gTWVzc2FnZXMudGV4dENoYXRzLmJ5SWQodGlkKSgpXG4gIH0gY2F0Y2ggKGUpIHsgfVxuICBpZiAoIXRocmVhZCkge1xuICAgIHRyeSB7XG4gICAgICB0aHJlYWQgPSBNZXNzYWdlcy5idWRkaWVzLndob3NlKHsgaGFuZGxlIH0pWzBdXG4gICAgfSBjYXRjaCAoZSkgeyB9XG4gIH1cbiAgTWVzc2FnZXMuc2VuZCh0eHQsIHsgdG86IHRocmVhZCB9KVxufVxuKVxudmFyIGFyZ3MgPSAkezB9XG52YXIgb3V0ICA9IGZuLmFwcGx5KG51bGwsIGFyZ3MpIl19";
NSString *embeddedBase64JSONBigSur = @"eyJhc2stZm9yLWF1dG9tYXRpb24iOlsiQXBwbGVTY3JpcHQiLCJ0ZWxsIGFwcGxpY2F0aW9uIFwiTWVzc2FnZXNcIiB0byBzZXQgYSB0byBhY2NvdW50c1xuIl0sImNyZWF0ZS10aHJlYWQiOlsiQXBwbGVTY3JpcHQiLCJ0ZWxsIGFwcGxpY2F0aW9uIFwiTWVzc2FnZXNcIiB0byBzZXQgdGhyZWFkIHRvIG1ha2UgbmV3IGNoYXQgd2l0aCBwcm9wZXJ0aWVzIHtwYXJ0aWNpcGFudHM6eyAkezB9IH19XG5nZXQgdGhyZWFkXG4iXSwiaGlkZS1tZXNzYWdlcy1iZWhpbmQtdGV4dHMiOlsiQXBwbGVTY3JpcHQiLCJ0ZWxsIGFwcGxpY2F0aW9uIFwiU3lzdGVtIEV2ZW50c1wiXG50ZWxsIGFwcGxpY2F0aW9uIHByb2Nlc3MgXCIkezB9XCIgdG8gc2V0IHt0ZXh0c1NpemUsIHRleHRzUG9zfSB0byB7c2l6ZSwgcG9zaXRpb259IG9mIHdpbmRvdyAwXG50ZWxsIGFwcGxpY2F0aW9uIHByb2Nlc3MgXCJNZXNzYWdlc1wiIHRvIHRlbGwgd2luZG93IDAgdG8gc2V0IHtzaXplLCBwb3NpdGlvbn0gdG8ge3RleHRzU2l6ZSwgdGV4dHNQb3N9XG5lbmQgdGVsbFxuIl0sImhpZGUtbWVzc2FnZXMiOlsiQXBwbGVTY3JpcHQiLCJ0ZWxsIGFwcGxpY2F0aW9uIFwiU3lzdGVtIEV2ZW50c1wiXG50ZWxsIHByb2Nlc3MgXCJNZXNzYWdlc1wiIHRvIHNldCB2aXNpYmxlIHRvIGZhbHNlXG50ZWxsIGFwcGxpY2F0aW9uIFwiTWVzc2FnZXNcIiB0byBjbG9zZSB3aW5kb3cgMFxuZW5kIHRlbGxcbiJdLCJtZXNzYWdlcy1ydW5uaW5nIjpbIkFwcGxlU2NyaXB0IiwiZ2V0IHJ1bm5pbmcgb2YgYXBwbGljYXRpb24gXCJNZXNzYWdlc1wiXG4iXSwibWVzc2FnZXMtdmlzaWJsZSI6WyJBcHBsZVNjcmlwdCIsInRlbGwgYXBwbGljYXRpb24gXCJTeXN0ZW0gRXZlbnRzXCIgdG8gc2V0IGFwcFZpc2libGUgdG8gdmlzaWJsZSBvZiBwcm9jZXNzIFwiTWVzc2FnZXNcIlxuIl0sInNlbmQtZmlsZSI6WyJKYXZhU2NyaXB0IiwiT2JqQy5pbXBvcnQoJ3N0ZGxpYicpXG52YXIgZm4gPSAoZnVuY3Rpb24gKHRpZCwgZnAsIGhhbmRsZSkge1xuICBjb25zdCBNZXNzYWdlcyA9IEFwcGxpY2F0aW9uKCdNZXNzYWdlcycpXG4gIGNvbnN0IHRocmVhZCA9IE1lc3NhZ2VzLmNoYXRzLmJ5SWQodGlkKSgpXG4gIE1lc3NhZ2VzLnNlbmQoUGF0aChmcCksIHsgdG86IHRocmVhZCB9KVxufVxuKVxudmFyIGFyZ3MgPSAkezB9XG52YXIgb3V0ICA9IGZuLmFwcGx5KG51bGwsIGFyZ3MpIl0sInNlbmQtdGV4dCI6WyJKYXZhU2NyaXB0IiwiT2JqQy5pbXBvcnQoJ3N0ZGxpYicpXG52YXIgZm4gPSAoZnVuY3Rpb24gKHRpZCwgdHh0LCBoYW5kbGUpIHtcbiAgY29uc3QgTWVzc2FnZXMgPSBBcHBsaWNhdGlvbignTWVzc2FnZXMnKVxuICBjb25zdCB0aHJlYWQgPSBNZXNzYWdlcy5jaGF0cy5ieUlkKHRpZCkoKVxuICBNZXNzYWdlcy5zZW5kKHR4dCwgeyB0bzogdGhyZWFkIH0pXG59XG4pXG52YXIgYXJncyA9ICR7MH1cbnZhciBvdXQgID0gZm4uYXBwbHkobnVsbCwgYXJncykiXX0=";

@implementation AppleScriptRunner

- (bool) isBigSur {
    NSOperatingSystemVersion osversion = [[NSProcessInfo processInfo] operatingSystemVersion];
    bool isBigSur = osversion.majorVersion >= 11 || osversion.minorVersion >= 16;
    return isBigSur;
}

- (void) loadFromEmbeddedJSON {
    bool isBigSur = [self isBigSur];
    // if (isBigSur) NSLog(@"loading bigsur embedded JSON");

    NSData *embeddedData = [[NSData alloc] initWithBase64EncodedString:(isBigSur ? embeddedBase64JSONBigSur : embeddedBase64JSON) options:0];
    NSDictionary *data = [NSJSONSerialization JSONObjectWithData:embeddedData options:NSUTF8StringEncoding error:nil];

    NSLog(@"Loaded %lu scripts", (unsigned long)[data count]);

    [self setScripts:data];
}
// - (void) generateJSON {
//     NSData *data = [NSJSONSerialization dataWithJSONObject:[self scripts] options:NSJSONWritingSortedKeys error:nil];
//     NSString *str = [data base64EncodedStringWithOptions:0];
//     NSLog(@"Embedded: %@", str);
// }
// - (void) loadScripts: (NSURL *)directory {
//     bool isBigSur = [self isBigSur];

//     NSString *jstemplate = @"ObjC.import('stdlib')\nvar fn = (%@)\nvar args = ${0}\nvar out  = fn.apply(null, args)\nJSON.stringify(out)";

//     NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[directory path] error:NULL];
//     NSMutableDictionary *data = [[NSMutableDictionary alloc] init];
//     for (int count = 0; count < (int)[files count]; count++)
//     {
//         NSArray *arr = [files[count] componentsSeparatedByString:@"."];
//         NSString *lang = [arr[1]  isEqual: @"applescript"] ? @"AppleScript" : @"JavaScript";

//         NSString *str = [[NSString alloc] initWithContentsOfURL:[directory URLByAppendingPathComponent:files[count]] encoding:NSUTF8StringEncoding error:nil];
//         NSString *final = [lang  isEqual: @"JavaScript"] ? [NSString stringWithFormat:jstemplate, str] : str;

//         data[ arr[0] ] = [[NSArray alloc] initWithObjects:lang, final, nil];
//     }
//     for (NSString *key in [data allKeys]) {
//         NSString *bigsurOverride = [NSString stringWithFormat:@"%@-bigsur", key];
//         NSArray *value = [data objectForKey:bigsurOverride];
//         if (value != nil) {
//             if (isBigSur) {
//                 NSLog(@"Overriding for BigSur: %@", key);
//                 data[key] = value;
//             } else NSLog(@"Discarding BigSur: %@", bigsurOverride);

//             [data removeObjectForKey:bigsurOverride];
//         }
//     }

//     NSLog(@"Loaded %lu scripts", (unsigned long)[data count]);

//     [self setScripts:data];
// }
- (NSData *) executeScript: (NSString *)name :(NSString *)tag :(NSArray *)args {
    NSMutableDictionary *output = [[NSMutableDictionary alloc] init];
    output[@"tag"] = tag;

    NSDictionary *dict;
    NSArray *arr = [[self scripts] objectForKey:name];
    if (!arr) {
        output[@"error"] = @"Script not found";
    } else {
        NSString *lang = arr[0];
        NSString *source = arr[1];

        if (args) {
            for (int i = 0; i < [args count];i++) {
                source = [source stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"${%d}",i] withString:args[i]];
            }
        }

        OSAScript *scpt = [[OSAScript alloc] initWithSource:source language:[OSALanguage languageForName:lang]];
        NSString *desc = [[scpt executeAndReturnError:&dict] description];

        if (dict && [[dict allKeys] count] > 0) {
            output[@"error"] = [dict debugDescription];
        } else if (desc) {
            NSString *pattern = @"'utxt'\\(\"(.+)\"\\)";
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
            NSTextCheckingResult *match = [regex firstMatchInString:desc options:0 range:NSMakeRange(0, [desc length])];

            if (match != nil) {
                output[@"output"] = [desc substringWithRange:[match rangeAtIndex:1]];
            }
        }
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingFragmentsAllowed error:nil];
    return data;
}

@end
