/*
 * UNFS3 stable filesystem IDs (Linux)
 * see file LICENSE for license details
 */

#ifndef UNFS3_STABLE_FSID_H
#define UNFS3_STABLE_FSID_H

#ifdef __linux__
#include <sys/types.h>
#include <sys/stat.h>

/* -S auto: derive an ID for every CIFS/SMB3 mount from its server path */
void sfsid_enable_auto(void);
/* -S <mountpoint>=<id>: set the ID of one mounted filesystem; 0 on success */
int sfsid_add_manual(const char *spec);

/* stat family with st_dev replaced by the stable ID, where one applies */
int sfsid_stat(const char *path, struct stat *buf);
int sfsid_lstat(const char *path, struct stat *buf);
int sfsid_fstat(int fd, struct stat *buf);
#endif

#endif
