//
//  iTermTextShaderCommon.metal
//  iTerm2
//
//  Created by George Nachman on 7/2/18.
//

#include <metal_stdlib>
using namespace metal;
#import "iTermTextShaderCommon.h"


// Fills in result with color of neighboring pixels in texture. Result must hold 8 float4's.
void SampleNeighbors(float2 textureSize,
                     float2 textureOffset,
                     float2 textureCoordinate,
                     float2 glyphSize,
                     float scale,
                     texture2d<float> texture,
                     sampler textureSampler,
                     thread float4 *result) {
    const float2 pixel = (scale / 2) / textureSize;
    // I have to inset the limits by one pixel on the left and right. I guess
    // this is because clip space coordinates represent the center of a pixel,
    // so they are offset by a float pixel and will sample their neighbors. I'm
    // not 100% sure what's going on here, but it's definitely required.
    const float2 minTextureCoord = textureOffset + pixel;
    const float2 maxTextureCoord = minTextureCoord + (glyphSize / textureSize) - (scale * pixel.x * 2);

    result[0] = texture.sample(textureSampler, clamp(textureCoordinate + float2(-pixel.x, -pixel.y), minTextureCoord, maxTextureCoord));
    result[1] = texture.sample(textureSampler, clamp(textureCoordinate + float2(       0, -pixel.y), minTextureCoord, maxTextureCoord));
    result[2] = texture.sample(textureSampler, clamp(textureCoordinate + float2( pixel.x, -pixel.y), minTextureCoord, maxTextureCoord));
    result[3] = texture.sample(textureSampler, clamp(textureCoordinate + float2(-pixel.x,        0), minTextureCoord, maxTextureCoord));
    result[4] = texture.sample(textureSampler, clamp(textureCoordinate + float2( pixel.x,        0), minTextureCoord, maxTextureCoord));
    result[5] = texture.sample(textureSampler, clamp(textureCoordinate + float2(-pixel.x,  pixel.y), minTextureCoord, maxTextureCoord));
    result[6] = texture.sample(textureSampler, clamp(textureCoordinate + float2(       0,  pixel.y), minTextureCoord, maxTextureCoord));
    result[7] = texture.sample(textureSampler, clamp(textureCoordinate + float2( pixel.x,  pixel.y), minTextureCoord, maxTextureCoord));
}

// Sample eight neighbors of textureCoordinate and returns a value with the minimum components from all of them.
float4 GetMinimumColorComponentsOfNeighbors(float2 textureSize,
                                           float2 textureOffset,
                                           float2 textureCoordinate,
                                           float2 glyphSize,
                                           float scale,
                                           texture2d<float> texture,
                                           sampler textureSampler) {
    float4 neighbors[8];
    SampleNeighbors(textureSize,
                    textureOffset,
                    textureCoordinate,
                    glyphSize,
                    scale,
                    texture,
                    textureSampler,
                    neighbors);

    const float4 mask = min(neighbors[0],
                           min(neighbors[1],
                               min(neighbors[2],
                                   min(neighbors[3],
                                       min(neighbors[4],
                                           min(neighbors[5],
                                               min(neighbors[6],
                                                   neighbors[7])))))));
    return mask;
}

// Sample eight neighbors of textureCoordinate and returns a value with the maximum components from all of them.
float4 GetMaximumColorComponentsOfNeighbors(float2 textureSize,
                                           float2 textureOffset,
                                           float2 textureCoordinate,
                                           float2 glyphSize,
                                           float scale,
                                           texture2d<float> texture,
                                           sampler textureSampler) {
    float4 neighbors[8];
    SampleNeighbors(textureSize,
                    textureOffset,
                    textureCoordinate,
                    glyphSize,
                    scale,
                    texture,
                    textureSampler,
                    neighbors);

    const float4 mask = max(neighbors[0],
                           max(neighbors[1],
                               max(neighbors[2],
                                   max(neighbors[3],
                                       max(neighbors[4],
                                           max(neighbors[5],
                                               max(neighbors[6],
                                                   neighbors[7])))))));
    return mask;
}

// Computes the fraction of a pixel in clipspace coordinates that intersects a range of scanlines.
float FractionOfPixelThatIntersectsUnderline(float2 clipSpacePosition,
                                             float2 viewportSize,
                                             float2 cellOffset,
                                             float underlineOffset,
                                             float underlineThickness) {
    // Flip the clipSpacePosition and shift it by float a pixel so it refers to the minimum coordinate
    // that contains this pixel with y=0 on the bottom. This only considers the vertical position
    // of the line.
    float originOnScreenInPixelSpace = viewportSize.y - (clipSpacePosition.y - 0.5);
    float originOfCellInPixelSpace = originOnScreenInPixelSpace - cellOffset.y;

    // Compute a value between 0 and 1 giving how much of the range [y, y+1) intersects
    // the range [underlineOffset, underlineOffset + underlineThickness].
    const float lowerBound = max(originOfCellInPixelSpace, underlineOffset);
    const float upperBound = min(originOfCellInPixelSpace + 1, underlineOffset + underlineThickness);
    const float intersection = max(0.0, upperBound - lowerBound);

    return intersection;
}

// Call this with none, single, double, or strikethrough only. If you want strikethrough and an
// underline call it twice.
float FractionOfPixelThatIntersectsUnderlineForStyle(int underlineStyle,  // iTermMetalGlyphAttributesUnderline
                                                     float2 clipSpacePosition,
                                                     float2 viewportSize,
                                                     float2 cellOffset,
                                                     float underlineOffset,
                                                     float underlineThickness,
                                                     float scale) {
    if (underlineStyle == iTermMetalGlyphAttributesUnderlineDouble) {
        // We can't draw the underline lower than the bottom of the cell, so
        // move the lower underline down by one thickness, if possible, and
        // the second underline will draw above it. The same hack was added
        // to the non-metal code path so this isn't a glaring difference.
        underlineOffset = max(0.0, underlineOffset - underlineThickness);
    } else if (underlineStyle == iTermMetalGlyphAttributesUnderlineCurly) {
        underlineOffset = max(0.0, underlineOffset - underlineThickness / 2.0);
    }

    float weight = FractionOfPixelThatIntersectsUnderline(clipSpacePosition,
                                                          viewportSize,
                                                          cellOffset,
                                                          underlineOffset,
                                                          underlineThickness);
    switch (static_cast<iTermMetalGlyphAttributesUnderline>(underlineStyle)) {
        case iTermMetalGlyphAttributesUnderlineNone:
            return 0;

        case iTermMetalGlyphAttributesUnderlineStrikethrough:
        case iTermMetalGlyphAttributesUnderlineSingle:
            return weight;

        case iTermMetalGlyphAttributesUnderlineDouble:
            // Single & dashed
            if (weight > 0 && fmod(clipSpacePosition.x, 7 * scale) >= 4 * scale) {
                // Make a hole in the bottom underline
                return 0;
            } else if (weight == 0) {
                // Add a top underline if the y coordinate is right
                return FractionOfPixelThatIntersectsUnderline(clipSpacePosition,
                                                              viewportSize,
                                                              cellOffset,
                                                              underlineOffset + underlineThickness * 2,
                                                              underlineThickness);
            } else {
                // Visible part of dashed bottom underline
                return weight;
            }

        case iTermMetalGlyphAttributesUnderlineCurly: {
            const float wavelength = 6;
            if (weight > 0 && fmod(clipSpacePosition.x, (wavelength) * scale) >= (wavelength / 2) * scale) {
                // Make a hole in the bottom underline
                return 0;
            } else if (weight == 0 && !(fmod(clipSpacePosition.x, (wavelength) * scale) >= (wavelength / 2) * scale)) {
                // Make a hole in the top underline
                return 0;
            } else if (weight == 0) {
                // Add a top underline if the y coordinate is right
                return FractionOfPixelThatIntersectsUnderline(clipSpacePosition,
                                                              viewportSize,
                                                              cellOffset,
                                                              underlineOffset + underlineThickness,
                                                              underlineThickness);
            } else {
                // Visible part of dashed bottom underline
                return weight;
            }
        }

        case iTermMetalGlyphAttributesUnderlineDashedSingle:
            if (weight > 0 && fmod(clipSpacePosition.x, 7 * scale) >= 4 * scale) {
                return 0;
            } else {
                return weight;
            }

        case iTermMetalGlyphAttributesUnderlineStrikethroughAndSingle:
        case iTermMetalGlyphAttributesUnderlineStrikethroughAndDouble:
        case iTermMetalGlyphAttributesUnderlineStrikethroughAndDashedSingle:
        case iTermMetalGlyphAttributesUnderlineStrikethroughAndCurly:
            // This shouldn't happen.
            return 0;
    }

    // Shouldn't get here
    return weight;
}

float ComputeWeightOfUnderlineInverted(int underlineStyle,  // iTermMetalGlyphAttributesUnderline
                                       float2 clipSpacePosition,
                                       float2 viewportSize,
                                       float2 cellOffset,
                                       float2 underlineOffset,
                                       float underlineThickness,
                                       float2 textureSize,
                                       float2 textureOffset,
                                       float2 textureCoordinate,
                                       float2 glyphSize,
                                       float2 cellSize,
                                       texture2d<float> texture,
                                       sampler textureSampler,
                                       float scale,
                                       bool solid,
                                       bool predecessorWasUnderlined) {
    float thickness;
    float offset;
    switch (underlineStyle) {
        case iTermMetalGlyphAttributesUnderlineCurly:
            thickness = scale;
            offset = scale;
            break;
        case iTermMetalGlyphAttributesUnderlineDouble:
            thickness = underlineThickness;
            offset = scale;
            break;
        default:
            thickness = underlineThickness;
            offset = underlineOffset.y;
            break;
    }
    float weight = FractionOfPixelThatIntersectsUnderlineForStyle(underlineStyle,
                                                                  clipSpacePosition,
                                                                  viewportSize,
                                                                  cellOffset,
                                                                  offset,
                                                                  thickness,
                                                                  scale);
    if (weight == 0) {
        return 0;
    }
    const float margin = predecessorWasUnderlined ? 0 : underlineOffset.x;
    if (clipSpacePosition.x < cellOffset.x + margin) {
        return 0;
    }
    if (clipSpacePosition.x >= cellOffset.x + glyphSize.x) {
        return 0;
    }
    if (underlineStyle == iTermMetalGlyphAttributesUnderlineStrikethrough || solid) {
        return weight;
    }
    float4 mask = GetMinimumColorComponentsOfNeighbors(textureSize,
                                                      textureOffset,
                                                      textureCoordinate,
                                                      glyphSize,
                                                      scale,
                                                      texture,
                                                      textureSampler);
    float opacity = (mask.x + mask.y + mask.z) / 3.0;
    if (scale > 1) {
        if (opacity >= 0.99) {
            return weight;
        } else {
            return 0;
        }
    } else {
        return weight * min(1.0, pow(opacity * 1.1, 10));
    }
}

float ComputeWeightOfUnderlineRegular(int underlineStyle,  // iTermMetalGlyphAttributesUnderline
                                      float2 clipSpacePosition,
                                      float2 viewportSize,
                                      float2 cellOffset,
                                      float2 regularOffset,
                                      float regularThickness,
                                      float2 textureSize,
                                      float2 textureOffset,
                                      float2 textureCoordinate,
                                      float2 glyphSize,
                                      float2 cellSize,
                                      texture2d<float> texture,
                                      sampler textureSampler,
                                      float scale,
                                      bool solid,
                                      bool predecessorWasUnderlined) {
    float offset;
    float thickness;

    switch (underlineStyle) {
        case iTermMetalGlyphAttributesUnderlineCurly:
            thickness = scale;
            offset = scale;
            break;
        case iTermMetalGlyphAttributesUnderlineDouble:
            thickness = regularThickness;
            offset = scale;
            break;
        default:
            thickness = regularThickness;
            offset = regularOffset.y;
            break;
    }

    float weight = FractionOfPixelThatIntersectsUnderlineForStyle(underlineStyle,
                                                                  clipSpacePosition,
                                                                  viewportSize,
                                                                  cellOffset,
                                                                  offset,
                                                                  thickness,
                                                                  scale);
    if (weight == 0) {
        return 0;
    }
    const float margin = predecessorWasUnderlined ? 0 : regularOffset.x;
    if (clipSpacePosition.x < cellOffset.x + margin) {
        return 0;
    }
    if (clipSpacePosition.x >= cellOffset.x + glyphSize.x) {
        return 0;
    }
    if (underlineStyle == iTermMetalGlyphAttributesUnderlineStrikethrough || solid) {
        return weight;
    }
    float maxAlpha = GetMaximumColorComponentsOfNeighbors(textureSize,
                                                         textureOffset,
                                                         textureCoordinate,
                                                         glyphSize,
                                                         scale,
                                                         texture,
                                                         textureSampler).w;
    float opacity = 1 - maxAlpha;
    if (scale > 1) {
        if (opacity >= 0.99) {
            return weight;
        } else {
            return 0;
        }
    } else {
        return weight * min(1.0, pow(opacity * 1.1, 10));
    }
}

