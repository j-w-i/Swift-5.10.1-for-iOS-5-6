#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
extern int32_t runSwiftRouteProbe(void);
int main(void){@autoreleasepool{setvbuf(stdout,NULL,_IONBF,0);puts("entering Swift typed metadata checks");int32_t result=runSwiftRouteProbe();printf("Swift typed metadata result=%d\n",result);return result;}}
