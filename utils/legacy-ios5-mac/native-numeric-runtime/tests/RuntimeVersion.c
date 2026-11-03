// Test-only, read-only loaded-image identification using public dyld/Mach-O API.
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

int main(void) {
  for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
    const char *name = _dyld_get_image_name(i);
    if (!name || !strstr(name, "/libswiftCore.dylib")) continue;
    const struct mach_header *header = _dyld_get_image_header(i);
    const char *cursor = (const char *)header +
      (header->magic == MH_MAGIC_64 ? sizeof(struct mach_header_64) : sizeof(*header));
    printf("loadedCore=%s\n", name);
    for (uint32_t j = 0; j < header->ncmds; ++j) {
      const struct load_command *command = (const struct load_command *)cursor;
      if (command->cmd == LC_ID_DYLIB) {
        uint32_t version = ((const struct dylib_command *)command)->dylib.current_version;
        printf("loadedCoreCurrentVersion=%u.%u.%u\n", version >> 16,
               (version >> 8) & 255, version & 255);
      }
      if (command->cmd == LC_UUID) {
        const unsigned char *uuid = ((const struct uuid_command *)command)->uuid;
        printf("loadedCoreUUID=");
        for (int k = 0; k < 16; ++k) printf("%02X", uuid[k]);
        printf("\n");
      }
      cursor += command->cmdsize;
    }
    return 0;
  }
  fprintf(stderr, "libswiftCore was not loaded\n");
  return 1;
}
