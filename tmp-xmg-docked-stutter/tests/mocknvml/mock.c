#include <stdlib.h>
#include <stdio.h>
typedef struct { unsigned int currentMode, mode, supportedPowerMizerModes; } pm_t;
static unsigned int cur = 0;
int nvmlInit_v2(void) { return 0; }
int nvmlShutdown(void) { return 0; }
const char *nvmlErrorString(int r) { return r == 4 ? "Insufficient Permissions" : r == 2 ? "Invalid Argument" : "Unknown"; }
int nvmlDeviceGetHandleByIndex_v2(unsigned int i, void **d) { if (i) return 2; *d = (void*)0x1; return 0; }
int nvmlDeviceGetPowerMizerMode_v1(void *d, pm_t *p) { p->currentMode = cur; p->supportedPowerMizerModes = 0xF; return 0; }
int nvmlDeviceSetPowerMizerMode_v1(void *d, pm_t *p) { if (p->mode > 3) return 2; if (getenv("MOCK_EPERM")) return 4; cur = p->mode; fprintf(stderr, "[mock] set mode=%u\n", p->mode); return 0; }
