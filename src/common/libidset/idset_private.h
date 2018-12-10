/* Implemented as a Van Emde Boas tree using code.google.com/p/libveb.
 * T.D is data; T.M is size
 * All ops are O(log m), for key bitsize m: 2^m == T.M.
 */

#include "src/common/libutil/veb.h"
#include "idset.h"

struct idset {
    Veb T;
    int flags;
};

#define IDSET_ENCODE_CHUNK 1024
#define IDSET_DEFAULT_SIZE 1024 // default idset size if size=0

int validate_idset_flags (int flags, int allowed);

/*
 * vi:tabstop=4 shiftwidth=4 expandtab
 */
