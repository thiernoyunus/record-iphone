/*
 * Copyright (c) 2019 dsafa22, All Rights Reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 *================================================================
 * modified by fduncanh 2022
 *
 * Record iPhone overlay of UxPlay lib/mirror_buffer.c
 * (commit a3c19cbc7fcc870d74a0960bc97817a2569b4808).
 * Local change: snapshot/restore so a rejected trailer cannot
 * advance the shared AES-CTR stream.
 */

#include "mirror_buffer.h"
#include "raop_rtp.h"
#include "raop_rtp.h"
#include <stdint.h>
#include "crypto.h"
#include "compat.h"
#include <math.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <inttypes.h>

struct mirror_buffer_s {
    logger_t *logger;
    aes_ctx_t *aes_ctx;
    int nextDecryptCount;
    uint8_t og[16];
    /* audio aes key is used in a hash for the video aes key and iv */
    unsigned char aeskey_audio[RAOP_AESKEY_LEN];
};

void
mirror_buffer_init_aes(mirror_buffer_t *mirror_buffer, const uint64_t *streamConnectionID)
{
    unsigned char aeskey_video[64] = {0};
    unsigned char aesiv_video[64] = {0};

    assert(mirror_buffer);
    assert(streamConnectionID);
    
    /* AES key and IV */
    // Need secondary processing to use
    
    snprintf((char*) aeskey_video, sizeof(aeskey_video), "AirPlayStreamKey%" PRIu64, *streamConnectionID);
    snprintf((char*) aesiv_video, sizeof(aesiv_video), "AirPlayStreamIV%" PRIu64, *streamConnectionID);

    sha_ctx_t *ctx = sha_init();
    sha_update(ctx, aeskey_video, strlen((char*) aeskey_video));
    sha_update(ctx, mirror_buffer->aeskey_audio, RAOP_AESKEY_LEN);
    sha_final(ctx, aeskey_video, NULL);

    sha_reset(ctx);
    sha_update(ctx, aesiv_video, strlen((char*) aesiv_video));
    sha_update(ctx, mirror_buffer->aeskey_audio, RAOP_AESKEY_LEN);
    sha_final(ctx, aesiv_video, NULL);
    sha_destroy(ctx);

    if (mirror_buffer->aes_ctx) {
        aes_ctr_destroy(mirror_buffer->aes_ctx);
        mirror_buffer->aes_ctx = NULL;
    }
    mirror_buffer->nextDecryptCount = 0;
    memset(mirror_buffer->og, 0, sizeof(mirror_buffer->og));
    mirror_buffer->aes_ctx = aes_ctr_init(aeskey_video, aesiv_video);
}

mirror_buffer_t *
mirror_buffer_init(logger_t *logger, const unsigned char *aeskey)
{
    assert(aeskey);
    mirror_buffer_t *mirror_buffer = (mirror_buffer_t *) calloc(1, sizeof(mirror_buffer_t));
    if (!mirror_buffer) {
        return NULL;
    }
    memcpy(mirror_buffer->aeskey_audio, aeskey, RAOP_AESKEY_LEN);
    mirror_buffer->logger = logger;
    mirror_buffer->nextDecryptCount = 0;
    return mirror_buffer;
}

void mirror_buffer_decrypt(mirror_buffer_t *mirror_buffer, unsigned char* input, unsigned char* output, int inputLen) {
    /* If a packet is shorter than the carried-over partial block, only the
       first inputLen bytes can be recovered from the remainder. Consuming
       them keeps the AES-CTR stream aligned; the old code wrote
       nextDecryptCount bytes past the output buffer instead. */
    if (mirror_buffer->nextDecryptCount > 0) {
        int pending = mirror_buffer->nextDecryptCount;
        if (pending > inputLen) pending = inputLen;
        for (int i = 0; i < pending; i++) {
            output[i] = (input[i] ^ mirror_buffer->og[(16 - mirror_buffer->nextDecryptCount) + i]);
        }
        if (inputLen <= mirror_buffer->nextDecryptCount) {
            mirror_buffer->nextDecryptCount -= inputLen;
            return;
        }
        input += pending;
        output += pending;
        inputLen -= pending;
        mirror_buffer->nextDecryptCount = 0;
    }
    // Handling encrypted bytes
    int encryptlen = ((inputLen - mirror_buffer->nextDecryptCount) / 16) * 16;
    // Aes decryption
    aes_ctr_start_fresh_block(mirror_buffer->aes_ctx);
    aes_ctr_decrypt(mirror_buffer->aes_ctx, input + mirror_buffer->nextDecryptCount,
                    input + mirror_buffer->nextDecryptCount, encryptlen);
    // Copy to output
    memcpy(output + mirror_buffer->nextDecryptCount, input + mirror_buffer->nextDecryptCount, encryptlen);
    // int outputlength = mirror_buffer->nextDecryptCount + encryptlen;
    // Processing remaining length
    int restlen = (inputLen - mirror_buffer->nextDecryptCount) % 16;
    int reststart = inputLen - restlen;
    mirror_buffer->nextDecryptCount = 0;
    if (restlen > 0) {
        memset(mirror_buffer->og, 0, 16);
        memcpy(mirror_buffer->og, input + reststart, restlen);
        aes_ctr_decrypt(mirror_buffer->aes_ctx, mirror_buffer->og, mirror_buffer->og, 16);
        for (int j = 0; j < restlen; j++) {
            output[reststart + j] = mirror_buffer->og[j];
        }
        //outputlength += restlen;
        mirror_buffer->nextDecryptCount = 16 - restlen;// Difference 16-6=10 bytes
    }
}

void
mirror_buffer_destroy(mirror_buffer_t *mirror_buffer)
{
    if (mirror_buffer) {
        aes_ctr_destroy(mirror_buffer->aes_ctx);
        free(mirror_buffer);
    }
}

struct mirror_buffer_snap_s {
    int nextDecryptCount;
    uint8_t og[16];
    aes_ctx_t *aes_ctx;
};

mirror_buffer_snap_t *
mirror_buffer_snapshot(mirror_buffer_t *mirror_buffer)
{
    if (!mirror_buffer || !mirror_buffer->aes_ctx) return NULL;
    mirror_buffer_snap_t *snap = (mirror_buffer_snap_t *)calloc(1, sizeof(*snap));
    if (!snap) return NULL;
    snap->nextDecryptCount = mirror_buffer->nextDecryptCount;
    memcpy(snap->og, mirror_buffer->og, 16);
    snap->aes_ctx = aes_ctr_copy(mirror_buffer->aes_ctx);
    if (!snap->aes_ctx) {
        free(snap);
        return NULL;
    }
    return snap;
}

void
mirror_buffer_restore(mirror_buffer_t *mirror_buffer, mirror_buffer_snap_t *snap)
{
    if (!mirror_buffer || !snap || !snap->aes_ctx) return;
    aes_ctr_destroy(mirror_buffer->aes_ctx);
    mirror_buffer->aes_ctx = snap->aes_ctx;
    snap->aes_ctx = NULL;
    mirror_buffer->nextDecryptCount = snap->nextDecryptCount;
    memcpy(mirror_buffer->og, snap->og, 16);
}

void
mirror_buffer_snap_destroy(mirror_buffer_snap_t *snap)
{
    if (!snap) return;
    if (snap->aes_ctx) aes_ctr_destroy(snap->aes_ctx);
    free(snap);
}
