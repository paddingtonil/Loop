//
//  DirectConnect_ECC.h
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — P-256 point and scalar arithmetic for G7 pairing (J-PAKE).
//  Coded by Claude Code. Idea by Taylor Patterson.
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

#ifndef DirectConnect_ECC_h
#define DirectConnect_ECC_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// P-256 uses 32-byte scalars and two 32-byte coordinates for each raw affine point.
enum {
    DirectConnect_ECCScalarSize = 32,
    DirectConnect_ECCPointSize = 64
};

/// Generates one cryptographically random P-256 private scalar and its public point.
bool DirectConnect_ECCGenerateKeyPair(uint8_t publicKey[DirectConnect_ECCPointSize],
                                uint8_t privateKey[DirectConnect_ECCScalarSize]);

/// Rejects malformed, off-curve, and otherwise invalid raw public points.
bool DirectConnect_ECCIsValidPoint(const uint8_t point[DirectConnect_ECCPointSize]);

/// Adds two affine P-256 points and returns false when the result is the point at infinity.
bool DirectConnect_ECCPointAdd(const uint8_t left[DirectConnect_ECCPointSize],
                         const uint8_t right[DirectConnect_ECCPointSize],
                         uint8_t result[DirectConnect_ECCPointSize]);

/// Subtracts the right affine point from the left by negating its Y coordinate before addition.
bool DirectConnect_ECCPointSubtract(const uint8_t left[DirectConnect_ECCPointSize],
                              const uint8_t right[DirectConnect_ECCPointSize],
                              uint8_t result[DirectConnect_ECCPointSize]);

/// Multiplies an arbitrary validated affine point by a scalar.
bool DirectConnect_ECCPointMultiply(const uint8_t point[DirectConnect_ECCPointSize],
                              const uint8_t scalar[DirectConnect_ECCScalarSize],
                              uint8_t result[DirectConnect_ECCPointSize]);

/// Multiplies the standard P-256 generator by a scalar.
bool DirectConnect_ECCGeneratorMultiply(const uint8_t scalar[DirectConnect_ECCScalarSize],
                                  uint8_t result[DirectConnect_ECCPointSize]);

/// Produces a cryptographically random non-zero scalar below the P-256 group order.
bool DirectConnect_ECCScalarRandom(uint8_t scalar[DirectConnect_ECCScalarSize]);

/// Multiplies two scalars modulo the P-256 group order.
bool DirectConnect_ECCScalarMultiplyModN(const uint8_t left[DirectConnect_ECCScalarSize],
                                   const uint8_t right[DirectConnect_ECCScalarSize],
                                   uint8_t result[DirectConnect_ECCScalarSize]);

/// Subtracts the right scalar from the left modulo the P-256 group order.
bool DirectConnect_ECCScalarSubtractModN(const uint8_t left[DirectConnect_ECCScalarSize],
                                   const uint8_t right[DirectConnect_ECCScalarSize],
                                   uint8_t result[DirectConnect_ECCScalarSize]);

/// Reduces one 32-byte value into the valid scalar field.
void DirectConnect_ECCScalarReduceModN(const uint8_t scalar[DirectConnect_ECCScalarSize],
                                 uint8_t result[DirectConnect_ECCScalarSize]);

/// Hashes or truncates arbitrary input into a 32-byte value, then reduces it modulo the group order.
void DirectConnect_ECCScalarFromBytes(const uint8_t *bytes,
                                size_t length,
                                uint8_t result[DirectConnect_ECCScalarSize]);

#ifdef __cplusplus
}
#endif

#endif
