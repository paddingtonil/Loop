//
//  DirectConnect_ECC.c
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — P-256 point and scalar arithmetic for G7 pairing (J-PAKE).
//  Coded by Claude Code. Idea by Taylor Patterson.
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

// G7 Primary authentication needs P-256 point addition, subtraction and scalar operations that
// CryptoKit does not expose. micro-ecc is therefore compiled inside this one translation unit with
// its low-level VLI API enabled and every unused curve disabled. Including the implementation here
// is deliberate. Adding `uECC.c` separately to the Xcode Compile Sources phase would compile the
// same symbols twice and would lose these configuration flags.
//
// Vendored source: https://github.com/kmackay/micro-ecc
// Pinned revision: 541b3a78026420a3e369c4c9281c396b5e531113
// Loop's target turns many C conversion warnings into errors. micro-ecc is third-party code
// compiled unchanged, so warnings are silenced for this translation unit only rather than
// relaxing the settings for every Loop source file.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"

#define uECC_ENABLE_VLI_API 1
#define uECC_SUPPORTS_secp160r1 0
#define uECC_SUPPORTS_secp192r1 0
#define uECC_SUPPORTS_secp224r1 0
#define uECC_SUPPORTS_secp256r1 1
#define uECC_SUPPORTS_secp256k1 0
#define uECC_SUPPORT_COMPRESSED_POINT 0

#include "DirectConnect_ECC.h"

#include "micro-ecc/uECC.h"
#include "micro-ecc/uECC_vli.h"
#include "micro-ecc/uECC.c"

#include <string.h>
#include <stdlib.h>

static int DirectConnect_ECCRNG(uint8_t *dest, unsigned size) {
    // micro-ecc requests random bytes through this callback. `arc4random_buf` is backed by the
    // system cryptographic random source and fills the exact buffer supplied by the library.
    arc4random_buf(dest, size);
    return 1;
}

static uECC_Curve DirectConnect_ECCCurve(void) {
    // Resolve the one enabled curve lazily and install the random callback before any key or scalar
    // generation can occur. The static pointer is immutable after this first setup.
    static uECC_Curve curve = 0;
    if (!curve) {
        uECC_set_rng(DirectConnect_ECCRNG);
        curve = uECC_secp256r1();
    }
    return curve;
}

static unsigned DirectConnect_ECCNumWords(void) {
    return uECC_curve_num_words(DirectConnect_ECCCurve());
}

static const uint8_t DirectConnect_ECCGeneratorPoint[DirectConnect_ECCPointSize] = {
    0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47,
    0xf8, 0xbc, 0xe6, 0xe5, 0x63, 0xa4, 0x40, 0xf2,
    0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0,
    0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96,
    0x4f, 0xe3, 0x42, 0xe2, 0xfe, 0x1a, 0x7f, 0x9b,
    0x8e, 0xe7, 0xeb, 0x4a, 0x7c, 0x0f, 0x9e, 0x16,
    0x2b, 0xce, 0x33, 0x57, 0x6b, 0x31, 0x5e, 0xce,
    0xcb, 0xb6, 0x40, 0x68, 0x37, 0xbf, 0x51, 0xf5
};

// micro-ecc stores its internal words in the platform's native order while every bridge function
// accepts the standard 32-byte big-endian scalar and 64-byte uncompressed point coordinates.
static void DirectConnect_ECCPointBytesToNative(uECC_word_t *pointWords,
                                          const uint8_t point[DirectConnect_ECCPointSize]) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    uECC_vli_bytesToNative(pointWords, point, DirectConnect_ECCScalarSize);
    uECC_vli_bytesToNative(pointWords + numWords, point + DirectConnect_ECCScalarSize, DirectConnect_ECCScalarSize);
}

static void DirectConnect_ECCPointNativeToBytes(uint8_t point[DirectConnect_ECCPointSize],
                                          const uECC_word_t *pointWords) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    uECC_vli_nativeToBytes(point, DirectConnect_ECCScalarSize, pointWords);
    uECC_vli_nativeToBytes(point + DirectConnect_ECCScalarSize, DirectConnect_ECCScalarSize, pointWords + numWords);
}

static void DirectConnect_ECCScalarBytesToNative(uECC_word_t *scalarWords,
                                           const uint8_t scalar[DirectConnect_ECCScalarSize]) {
    uECC_vli_bytesToNative(scalarWords, scalar, DirectConnect_ECCScalarSize);
}

static void DirectConnect_ECCScalarNativeToBytes(uint8_t scalar[DirectConnect_ECCScalarSize],
                                           const uECC_word_t *scalarWords) {
    uECC_vli_nativeToBytes(scalar, DirectConnect_ECCScalarSize, scalarWords);
}

static void DirectConnect_ECCSetSmall(uECC_word_t *target, unsigned value) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    memset(target, 0, sizeof(uECC_word_t) * numWords);
    target[0] = (uECC_word_t)value;
}

static void DirectConnect_ECCNegateY(const uECC_word_t *point, uECC_word_t *result) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    const uECC_word_t *mod = uECC_curve_p(DirectConnect_ECCCurve());

    // An affine P-256 point is negated by keeping X and replacing Y with `p - Y`. The special zero
    // value remains zero so the result stays in the expected internal representation.
    uECC_vli_set(result, point, numWords);
    if (uECC_vli_isZero(point + numWords, numWords)) {
        uECC_vli_clear(result + numWords, numWords);
        return;
    }

    uECC_vli_modSub(result + numWords, mod, point + numWords, mod, numWords);
}

static bool DirectConnect_ECCPointDoubleInternal(const uECC_word_t *point, uECC_word_t *result) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    const uECC_word_t *mod = uECC_curve_p(DirectConnect_ECCCurve());
    uECC_word_t x[numWords];
    uECC_word_t y[numWords];
    uECC_word_t numerator[numWords];
    uECC_word_t denominator[numWords];
    uECC_word_t inverse[numWords];
    uECC_word_t lambda[numWords];
    uECC_word_t tmp[numWords];
    uECC_word_t three[numWords];
    uECC_word_t two[numWords];

    // Doubling a point with Y equal to zero produces the point at infinity, which this wrapper
    // reports as a failed finite-point operation.
    if (uECC_vli_isZero(point + numWords, numWords)) {
        return false;
    }

    uECC_vli_set(x, point, numWords);
    uECC_vli_set(y, point + numWords, numWords);
    DirectConnect_ECCSetSmall(three, 3);
    DirectConnect_ECCSetSmall(two, 2);

    // Calculate the affine tangent slope for secp256r1 where the curve parameter `a` is minus 3.
    uECC_vli_modSquare_fast(numerator, x, DirectConnect_ECCCurve());
    uECC_vli_modMult(numerator, numerator, three, mod, numWords);
    uECC_vli_modSub(numerator, numerator, three, mod, numWords); /* a = -3 for secp256r1 */

    uECC_vli_modMult(denominator, y, two, mod, numWords);
    if (uECC_vli_isZero(denominator, numWords)) {
        return false;
    }

    uECC_vli_modInv(inverse, denominator, mod, numWords);
    uECC_vli_modMult(lambda, numerator, inverse, mod, numWords);

    // Apply the standard affine formulas to recover the doubled X and Y coordinates.
    uECC_vli_modSquare_fast(result, lambda, DirectConnect_ECCCurve());
    uECC_vli_modMult(tmp, x, two, mod, numWords);
    uECC_vli_modSub(result, result, tmp, mod, numWords);

    uECC_vli_modSub(tmp, x, result, mod, numWords);
    uECC_vli_modMult(result + numWords, lambda, tmp, mod, numWords);
    uECC_vli_modSub(result + numWords, result + numWords, y, mod, numWords);
    return true;
}

// micro-ecc exposes point multiplication but not general affine point addition. J-PAKE requires
// both operations, so the bridge implements the standard P-256 affine formulas using micro-ecc's
// tested modular arithmetic. The point at infinity is reported as `false` to the caller.
static bool DirectConnect_ECCPointAddInternal(const uECC_word_t *left,
                                        const uECC_word_t *right,
                                        uECC_word_t *result) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    const uECC_word_t *mod = uECC_curve_p(DirectConnect_ECCCurve());
    uECC_word_t dx[numWords];
    uECC_word_t dy[numWords];
    uECC_word_t inverse[numWords];
    uECC_word_t lambda[numWords];
    uECC_word_t tmp[numWords];
    uECC_word_t negated[numWords * 2];

    if (uECC_vli_equal(left, right, numWords) &&
        uECC_vli_equal(left + numWords, right + numWords, numWords)) {
        return DirectConnect_ECCPointDoubleInternal(left, result);
    }

    DirectConnect_ECCNegateY(right, negated);
    if (uECC_vli_equal(left, negated, numWords) &&
        uECC_vli_equal(left + numWords, negated + numWords, numWords)) {
        return false;
    }

    uECC_vli_modSub(dx, right, left, mod, numWords);
    if (uECC_vli_isZero(dx, numWords)) {
        return false;
    }
    uECC_vli_modSub(dy, right + numWords, left + numWords, mod, numWords);

    uECC_vli_modInv(inverse, dx, mod, numWords);
    uECC_vli_modMult(lambda, dy, inverse, mod, numWords);

    uECC_vli_modSquare_fast(result, lambda, DirectConnect_ECCCurve());
    uECC_vli_modSub(result, result, left, mod, numWords);
    uECC_vli_modSub(result, result, right, mod, numWords);

    uECC_vli_modSub(tmp, left, result, mod, numWords);
    uECC_vli_modMult(result + numWords, lambda, tmp, mod, numWords);
    uECC_vli_modSub(result + numWords, result + numWords, left + numWords, mod, numWords);
    return true;
}

bool DirectConnect_ECCGenerateKeyPair(uint8_t publicKey[DirectConnect_ECCPointSize],
                                uint8_t privateKey[DirectConnect_ECCScalarSize]) {
    return uECC_make_key(publicKey, privateKey, DirectConnect_ECCCurve()) == 1;
}

bool DirectConnect_ECCIsValidPoint(const uint8_t point[DirectConnect_ECCPointSize]) {
    return uECC_valid_public_key(point, DirectConnect_ECCCurve()) == 1;
}

bool DirectConnect_ECCPointAdd(const uint8_t left[DirectConnect_ECCPointSize],
                         const uint8_t right[DirectConnect_ECCPointSize],
                         uint8_t result[DirectConnect_ECCPointSize]) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    uECC_word_t leftWords[numWords * 2];
    uECC_word_t rightWords[numWords * 2];
    uECC_word_t resultWords[numWords * 2];

    DirectConnect_ECCPointBytesToNative(leftWords, left);
    DirectConnect_ECCPointBytesToNative(rightWords, right);

    if (!DirectConnect_ECCPointAddInternal(leftWords, rightWords, resultWords)) {
        return false;
    }

    DirectConnect_ECCPointNativeToBytes(result, resultWords);
    return true;
}

bool DirectConnect_ECCPointSubtract(const uint8_t left[DirectConnect_ECCPointSize],
                              const uint8_t right[DirectConnect_ECCPointSize],
                              uint8_t result[DirectConnect_ECCPointSize]) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    uECC_word_t rightWords[numWords * 2];
    uECC_word_t negatedRight[numWords * 2];
    uint8_t negatedRightBytes[DirectConnect_ECCPointSize];

    DirectConnect_ECCPointBytesToNative(rightWords, right);
    DirectConnect_ECCNegateY(rightWords, negatedRight);
    DirectConnect_ECCPointNativeToBytes(negatedRightBytes, negatedRight);
    return DirectConnect_ECCPointAdd(left, negatedRightBytes, result);
}

bool DirectConnect_ECCPointMultiply(const uint8_t point[DirectConnect_ECCPointSize],
                              const uint8_t scalar[DirectConnect_ECCScalarSize],
                              uint8_t result[DirectConnect_ECCPointSize]) {
    const unsigned numWords = DirectConnect_ECCNumWords();
    const unsigned numNWords = uECC_curve_num_n_words(DirectConnect_ECCCurve());
    uECC_word_t pointWords[numWords * 2];
    uECC_word_t scalarWords[numNWords];
    uECC_word_t resultWords[numWords * 2];

    // micro-ecc's multiplier returns a wrong point for scalar one (see GeneratorMultiply);
    // 1·P is P.
    bool isOne = scalar[DirectConnect_ECCScalarSize - 1] == 0x01;
    for (size_t i = 0; i < DirectConnect_ECCScalarSize - 1 && isOne; i++) {
        isOne = scalar[i] == 0x00;
    }
    if (isOne) {
        memcpy(result, point, DirectConnect_ECCPointSize);
        return true;
    }

    // Convert both inputs into micro-ecc's native word order, perform the multiplication, then
    // restore the big-endian wire representation expected by the Objective-C bridge.
    DirectConnect_ECCPointBytesToNative(pointWords, point);
    DirectConnect_ECCScalarBytesToNative(scalarWords, scalar);
    uECC_point_mult(resultWords, pointWords, scalarWords, DirectConnect_ECCCurve());
    DirectConnect_ECCPointNativeToBytes(result, resultWords);
    return true;
}

bool DirectConnect_ECCGeneratorMultiply(const uint8_t scalar[DirectConnect_ECCScalarSize],
                                  uint8_t result[DirectConnect_ECCPointSize]) {
    static const uint8_t oneScalar[DirectConnect_ECCScalarSize] = {
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    };

    // micro-ecc's internal multiplier rejects some identity shortcuts. Return the published
    // generator directly for scalar one, then use the common arbitrary-point path for all others.
    if (memcmp(scalar, oneScalar, sizeof(oneScalar)) == 0) {
        memcpy(result, DirectConnect_ECCGeneratorPoint, DirectConnect_ECCPointSize);
        return true;
    }

    return DirectConnect_ECCPointMultiply(DirectConnect_ECCGeneratorPoint, scalar, result);
}

bool DirectConnect_ECCScalarRandom(uint8_t scalar[DirectConnect_ECCScalarSize]) {
    const unsigned numNWords = uECC_curve_num_n_words(DirectConnect_ECCCurve());
    uECC_word_t scalarWords[numNWords];
    // Request a non-zero integer below the group order rather than reducing unrestricted random
    // bytes, which avoids bias and invalid zero scalars.
    if (!uECC_generate_random_int(scalarWords, uECC_curve_n(DirectConnect_ECCCurve()), numNWords)) {
        return false;
    }
    DirectConnect_ECCScalarNativeToBytes(scalar, scalarWords);
    return true;
}

bool DirectConnect_ECCScalarMultiplyModN(const uint8_t left[DirectConnect_ECCScalarSize],
                                   const uint8_t right[DirectConnect_ECCScalarSize],
                                   uint8_t result[DirectConnect_ECCScalarSize]) {
    const unsigned numNWords = uECC_curve_num_n_words(DirectConnect_ECCCurve());
    uECC_word_t leftWords[numNWords];
    uECC_word_t rightWords[numNWords];
    uECC_word_t resultWords[numNWords];

    DirectConnect_ECCScalarBytesToNative(leftWords, left);
    DirectConnect_ECCScalarBytesToNative(rightWords, right);
    uECC_vli_modMult(resultWords, leftWords, rightWords, uECC_curve_n(DirectConnect_ECCCurve()), numNWords);
    DirectConnect_ECCScalarNativeToBytes(result, resultWords);
    return true;
}

bool DirectConnect_ECCScalarSubtractModN(const uint8_t left[DirectConnect_ECCScalarSize],
                                   const uint8_t right[DirectConnect_ECCScalarSize],
                                   uint8_t result[DirectConnect_ECCScalarSize]) {
    const unsigned numNWords = uECC_curve_num_n_words(DirectConnect_ECCCurve());
    uECC_word_t leftWords[numNWords];
    uECC_word_t rightWords[numNWords];
    uECC_word_t resultWords[numNWords];

    DirectConnect_ECCScalarBytesToNative(leftWords, left);
    DirectConnect_ECCScalarBytesToNative(rightWords, right);
    uECC_vli_modSub(resultWords, leftWords, rightWords, uECC_curve_n(DirectConnect_ECCCurve()), numNWords);
    DirectConnect_ECCScalarNativeToBytes(result, resultWords);
    return true;
}

void DirectConnect_ECCScalarReduceModN(const uint8_t scalar[DirectConnect_ECCScalarSize],
                                 uint8_t result[DirectConnect_ECCScalarSize]) {
    const unsigned numNWords = uECC_curve_num_n_words(DirectConnect_ECCCurve());
    uECC_word_t scalarWords[numNWords];
    uECC_word_t reducedWords[numNWords];

    DirectConnect_ECCScalarBytesToNative(scalarWords, scalar);
    uECC_vli_set(reducedWords, scalarWords, numNWords);
    // The input has the same bit width as the group order, so at most one subtraction is required
    // to produce the canonical value below `n`.
    if (uECC_vli_cmp(reducedWords, uECC_curve_n(DirectConnect_ECCCurve()), numNWords) >= 0) {
        uECC_vli_sub(reducedWords, reducedWords, uECC_curve_n(DirectConnect_ECCCurve()), numNWords);
    }
    DirectConnect_ECCScalarNativeToBytes(result, reducedWords);
}

void DirectConnect_ECCScalarFromBytes(const uint8_t *bytes,
                                size_t length,
                                uint8_t result[DirectConnect_ECCScalarSize]) {
    memset(result, 0, DirectConnect_ECCScalarSize);
    if (bytes == NULL || length == 0) {
        return;
    }

    // Retain the least significant 32 bytes of a longer digest or left-pad a shorter value. The
    // caller performs any required modular reduction after this fixed-width conversion.
    if (length >= DirectConnect_ECCScalarSize) {
        memcpy(result, bytes + (length - DirectConnect_ECCScalarSize), DirectConnect_ECCScalarSize);
    } else {
        memcpy(result + (DirectConnect_ECCScalarSize - length), bytes, length);
    }
}

#pragma clang diagnostic pop
