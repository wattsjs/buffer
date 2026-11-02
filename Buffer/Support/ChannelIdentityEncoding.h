#ifndef BUFFER_CHANNEL_IDENTITY_ENCODING_H
#define BUFFER_CHANNEL_IDENTITY_ENCODING_H

#include <stdint.h>

/// Encode all 32 SHA-256 bytes as unpadded URL-safe Base64, prefixed by m3u:.
/// The caller supplies exactly 32 input bytes and at least 47 output bytes.
/// Output is ASCII, has no NUL terminator, and the returned length is 47.
static inline intptr_t buffer_encode_channel_digest(const uint8_t *digest, uint8_t *output) {
    static const uint8_t alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    output[0] = 'm'; output[1] = '3'; output[2] = 'u'; output[3] = ':';
    intptr_t offset = 4;
    for (int index = 0; index < 30; index += 3) {
        uint32_t bits = ((uint32_t)digest[index] << 16)
            | ((uint32_t)digest[index + 1] << 8) | digest[index + 2];
        output[offset++] = alphabet[(bits >> 18) & 63];
        output[offset++] = alphabet[(bits >> 12) & 63];
        output[offset++] = alphabet[(bits >> 6) & 63];
        output[offset++] = alphabet[bits & 63];
    }
    output[offset++] = alphabet[digest[30] >> 2];
    output[offset++] = alphabet[((digest[30] & 3) << 4) | (digest[31] >> 4)];
    output[offset++] = alphabet[(digest[31] & 15) << 2];
    return offset;
}

#endif
