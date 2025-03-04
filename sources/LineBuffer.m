// -*- mode:objc -*-
// $Id: $
/*
 **  LineBuffer.h
 **
 **  Copyright (c) 2002, 2003
 **
 **  Author: George Nachman
 **
 **  Project: iTerm
 **
 **  Description: Implements a buffer of lines. It can hold a large number
 **   of lines and can quickly format them to a fixed width.
 **
 **  This program is free software; you can redistribute it and/or modify
 **  it under the terms of the GNU General Public License as published by
 **  the Free Software Foundation; either version 2 of the License, or
 **  (at your option) any later version.
 **
 **  This program is distributed in the hope that it will be useful,
 **  but WITHOUT ANY WARRANTY; without even the implied warranty of
 **  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 **  GNU General Public License for more details.
 **
 **  You should have received a copy of the GNU General Public License
 **  along with this program; if not, write to the Free Software
 **  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#import "LineBuffer.h"

#import "BackgroundThread.h"
#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermLineBlockArray.h"
#import "iTermMalloc.h"
#import "iTermOrderedDictionary.h"
#import "LineBlock.h"
#import "NSArray+iTerm.h"
#import "NSData+iTerm.h"
#import "RegexKitLite.h"

static NSString *const kLineBufferVersionKey = @"Version";
static NSString *const kLineBufferBlocksKey = @"Blocks";
static NSString *const kLineBufferBlockSizeKey = @"Block Size";
static NSString *const kLineBufferCursorXKey = @"Cursor X";
static NSString *const kLineBufferCursorRawlineKey = @"Cursor Rawline";
static NSString *const kLineBufferMaxLinesKey = @"Max Lines";
static NSString *const kLineBufferNumDroppedBlocksKey = @"Num Dropped Blocks";
static NSString *const kLineBufferDroppedCharsKey = @"Dropped Chars";
static NSString *const kLineBufferTruncatedKey = @"Truncated";
static NSString *const kLineBufferMayHaveDWCKey = @"May Have Double Width Character";
static NSString *const kLineBufferBlockWrapperKey = @"Block Wrapper";

static const int kLineBufferVersion = 1;
static const NSInteger kUnicodeVersion = 9;

@implementation LineBuffer {
    // An array of LineBlock*s.
    iTermLineBlockArray *_lineBlocks;

    // The default storage for a LineBlock (some may be larger to accommodate very long lines).
    int block_size;

    // If a cursor size is saved, this gives its offset from the start of its line.
    int cursor_x;

    // The raw line number (in lines from the first block) of the cursor.
    int cursor_rawline;

    // The maximum number of lines to store. In truth, more lines will be stored, but no more
    // than max_lines will be exposed by the interface.
    int max_lines;

    // The number of blocks at the head of the list that have been removed.
    int num_dropped_blocks;

    // Cache of the number of wrapped lines
    int num_wrapped_lines_cache;
    int num_wrapped_lines_width;

    // Number of char that have been dropped
    long long droppedChars;
}

// Append a block
- (LineBlock*)_addBlockOfSize:(int)size {
    LineBlock* block = [[LineBlock alloc] initWithRawBufferSize: size];
    block.mayHaveDoubleWidthCharacter = self.mayHaveDoubleWidthCharacter;
    [_lineBlocks addBlock:block];
    [block release];
    return block;
}

- (instancetype)init {
    // I picked 8k because it's a multiple of the page size and should hold about 100-200 lines
    // on average. Very small blocks make finding a wrapped line expensive because caching the
    // number of wrapped lines is spread out over more blocks. Very large blocks are expensive
    // because of the linear search through a block for the start of a wrapped line. This is
    // in the middle. Ideally, the number of blocks would equal the number of wrapped lines per
    // block, and this should be in that neighborhood for typical uses.
    const int BLOCK_SIZE = 1024 * 8;
    return [self initWithBlockSize:BLOCK_SIZE];
}

- (void)commonInit {
    _lineBlocks = [[iTermLineBlockArray alloc] init];
    max_lines = -1;
    num_wrapped_lines_width = -1;
    num_dropped_blocks = 0;
}

// The designated initializer. We prefer not to expose the notion of block sizes to
// clients, so this is internal.
- (LineBuffer*)initWithBlockSize:(int)bs
{
    self = [super init];
    if (self) {
        [self commonInit];
        block_size = bs;
        [self _addBlockOfSize:block_size];
    }
    return self;
}

- (LineBuffer *)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self) {
        [self commonInit];
        if ([dictionary[kLineBufferVersionKey] intValue] != kLineBufferVersion) {
            [self autorelease];
            return nil;
        }
        _mayHaveDoubleWidthCharacter = [dictionary[kLineBufferMayHaveDWCKey] boolValue];
        block_size = [dictionary[kLineBufferBlockSizeKey] intValue];
        cursor_x = [dictionary[kLineBufferCursorXKey] intValue];
        cursor_rawline = [dictionary[kLineBufferCursorRawlineKey] intValue];
        max_lines = [dictionary[kLineBufferMaxLinesKey] intValue];
        num_dropped_blocks = [dictionary[kLineBufferNumDroppedBlocksKey] intValue];
        droppedChars = [dictionary[kLineBufferDroppedCharsKey] longLongValue];
        for (NSDictionary *maybeWrapper in dictionary[kLineBufferBlocksKey]) {
            NSDictionary *blockDictionary = maybeWrapper;
            if (maybeWrapper[kLineBufferBlockWrapperKey]) {
                blockDictionary = maybeWrapper[kLineBufferBlockWrapperKey];
            }
            LineBlock *block = [LineBlock blockWithDictionary:blockDictionary];
            if (!block) {
                [self autorelease];
                return nil;
            }
            [_lineBlocks addBlock:block];
        }
    }
    return self;
}

- (void)dealloc {
    [_lineBlocks release];
    [super dealloc];
}

- (void)setMayHaveDoubleWidthCharacter:(BOOL)mayHaveDoubleWidthCharacter {
    if (!_mayHaveDoubleWidthCharacter) {
        _mayHaveDoubleWidthCharacter = mayHaveDoubleWidthCharacter;
        [_lineBlocks setAllBlocksMayHaveDoubleWidthCharacters];
    }
}

// This is called a lot so it's a C function to avoid obj_msgSend
static int RawNumLines(LineBuffer* buffer, int width) {
    if (buffer->num_wrapped_lines_width == width) {
        return buffer->num_wrapped_lines_cache;
    }

    int count;
    count = [buffer->_lineBlocks numberOfWrappedLinesForWidth:width];

    buffer->num_wrapped_lines_width = width;
    buffer->num_wrapped_lines_cache = count;
    return count;
}


- (void) setMaxLines: (int) maxLines
{
    max_lines = maxLines;
    num_wrapped_lines_width = -1;
}


- (int)dropExcessLinesWithWidth: (int) width
{
    int nl = RawNumLines(self, width);
    int totalDropped = 0;
    if (max_lines != -1 && nl > max_lines) {
        LineBlock *block = _lineBlocks[0];
        int total_lines = nl;
        while (total_lines > max_lines) {
            int extra_lines = total_lines - max_lines;

            int block_lines = [block getNumLinesWithWrapWidth: width];
#if ITERM_DEBUG
            ITAssertWithMessage(block_lines > 0, @"Empty leading block");
#endif
            int toDrop = block_lines;
            if (toDrop > extra_lines) {
                toDrop = extra_lines;
            }
            int charsDropped;
            int dropped = [block dropLines:toDrop withWidth:width chars:&charsDropped];
            totalDropped += dropped;
            droppedChars += charsDropped;
            if ([block isEmpty]) {
                [_lineBlocks removeFirstBlock];
                ++num_dropped_blocks;
                if (_lineBlocks.count > 0) {
                    block = _lineBlocks[0];
                }
            }
            total_lines -= dropped;
        }
        num_wrapped_lines_cache = total_lines;
    }
#if ITERM_DEBUG
    assert(totalDropped == (nl - RawNumLines(self, width)));
#endif
    [_delegate lineBufferDidDropLines:self];
    return totalDropped;
}

- (NSString *)debugString {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < _lineBlocks.count; i++) {
        LineBlock *block = _lineBlocks[i];
        [block appendToDebugString:s];
    }
    return [s length] ? [s substringToIndex:s.length - 1] : @"";  // strip trailing newline
}

- (void) dump
{
    int i;
    int rawOffset = 0;
    for (i = 0; i < _lineBlocks.count; ++i) {
        NSLog(@"Block %d:\n", i);
        [_lineBlocks[i] dump:rawOffset toDebugLog:NO];
        rawOffset += [_lineBlocks[i] rawSpaceUsed];
    }
}

- (NSString *)compactLineDumpWithWidth:(int)width andContinuationMarks:(BOOL)continuationMarks {
    NSMutableString *s = [NSMutableString string];
    int n = [self numLinesWithWidth:width];
    for (int i = 0; i < n; i++) {
        screen_char_t continuation;
        ScreenCharArray *line = [self wrappedLineAtIndex:i width:width continuation:&continuation];
        if (!line) {
            [s appendFormat:@"(nil)"];
            continue;
        }
        [s appendFormat:@"%@", ScreenCharArrayToStringDebug(line.line, line.length)];
        for (int j = line.length; j < width; j++) {
            [s appendString:@"."];
        }
        if (continuationMarks) {
            if (continuation.code == EOL_HARD) {
                [s appendString:@"!"];
            } else if (continuation.code == EOL_SOFT) {
                [s appendString:@"+"];
            } else if (continuation.code == EOL_DWC) {
                [s appendString:@">"];
            } else {
                [s appendString:@"?"];
            }
        }
        if (i < n - 1) {
            [s appendString:@"\n"];
        }
    }
    return s;
}

- (void)dumpLinesWithWidth:(int)width {
    NSMutableString *s = [NSMutableString string];
    int n = [self numLinesWithWidth:width];
    int k = 0;
    for (int i = 0; i < n; i++) {
        screen_char_t continuation;
        ScreenCharArray *line = [self wrappedLineAtIndex:i width:width continuation:&continuation];
        [s appendFormat:@"%@", ScreenCharArrayToStringDebug(line.line, line.length)];
        for (int j = line.length; j < width; j++) {
            [s appendString:@"."];
        }
        if (continuation.code == EOL_HARD) {
            [s appendString:@"!"];
        } else if (continuation.code == EOL_SOFT) {
            [s appendString:@"+"];
        } else if (continuation.code == EOL_DWC) {
            [s appendString:@">"];
        } else {
            [s appendString:@"?"];
        }
        if (i < n - 1) {
            NSLog(@"%4d: %@", k++, s);
            s = [NSMutableString string];
        }
    }
    NSLog(@"%4d: %@", k++, s);
}

- (void)dumpWrappedToWidth:(int)width
{
    NSLog(@"%@", [self compactLineDumpWithWidth:width andContinuationMarks:NO]);
}

- (void)appendLine:(screen_char_t*)buffer
            length:(int)length
           partial:(BOOL)partial
             width:(int)width
         timestamp:(NSTimeInterval)timestamp
      continuation:(screen_char_t)continuation
{
#ifdef LOG_MUTATIONS
    NSLog(@"Append: %@\n", ScreenCharArrayToStringDebug(buffer, length));
#endif
    if (_lineBlocks.count == 0) {
        [self _addBlockOfSize:block_size];
    }

    LineBlock* block = _lineBlocks.lastBlock;

    int beforeLines = [block getNumLinesWithWrapWidth:width];
    if (![block appendLine:buffer
                    length:length
                   partial:partial
                     width:width
                 timestamp:timestamp
              continuation:continuation]) {
        // It's going to be complicated. Invalidate the number of wrapped lines
        // cache.
        num_wrapped_lines_width = -1;
        int prefix_len = 0;
        NSTimeInterval prefixTimestamp = 0;
        screen_char_t* prefix = NULL;
        if ([block hasPartial]) {
            // There is a line that's too long for the current block to hold.
            // Remove its prefix from the current block and later add the
            // concatenation of prefix + buffer to a larger block.
            screen_char_t* temp;
            BOOL ok = [block popLastLineInto:&temp
                                  withLength:&prefix_len
                                   upToWidth:[block rawBufferSize]+1
                                   timestamp:&prefixTimestamp
                                continuation:NULL];
            assert(ok);
            prefix = (screen_char_t*)iTermMalloc(MAX(1, prefix_len) * sizeof(screen_char_t));
            memcpy(prefix, temp, prefix_len * sizeof(screen_char_t));
            ITAssertWithMessage(ok, @"hasPartial but pop failed.");
        }
        if ([block isEmpty]) {
            // The buffer is empty but it's not large enough to hold a whole line. It must be grown.
            if (partial) {
                // The line is partial so we know there's more coming. Allocate enough space to hold the current line
                // plus the usual block size (this is the case when the line is freaking huge).
                // We could double the size to ensure better asymptotic runtime but you'd run out of memory
                // faster with huge lines.
                [block changeBufferSize: length + prefix_len + block_size];
            } else {
                // Allocate exactly enough space to hold this one line.
                [block changeBufferSize: length + prefix_len];
            }
        } else {
            // The existing buffer can't hold this line, but it has preceding line(s). Shrink it and
            // allocate a new buffer that is large enough to hold this line.
            [block shrinkToFit];
            if (length + prefix_len > block_size) {
                block = [self _addBlockOfSize:length + prefix_len];
            } else {
                block = [self _addBlockOfSize:block_size];
            }
        }

        // Append the prefix if there is one (the prefix was a partial line that we're
        // moving out of the last block into the new block)
        if (prefix) {
            BOOL ok __attribute__((unused)) =
                [block appendLine:prefix
                           length:prefix_len
                          partial:YES
                            width:width
                        timestamp:prefixTimestamp
                     continuation:continuation];
            ITAssertWithMessage(ok, @"append can't fail here");
            free(prefix);
        }
        // Finally, append this line to the new block. We know it'll fit because we made
        // enough room for it.
        BOOL ok __attribute__((unused)) =
            [block appendLine:buffer
                       length:length
                      partial:partial
                        width:width
                    timestamp:timestamp
                 continuation:continuation];
        ITAssertWithMessage(ok, @"append can't fail here");
    } else if (num_wrapped_lines_width == width) {
        // Straightforward addition of a line to an existing block. Update the
        // wrapped lines cache.
        int afterLines = [block getNumLinesWithWrapWidth:width];
        num_wrapped_lines_cache += (afterLines - beforeLines);
    } else {
        // Width change. Invalidate the wrapped lines cache.
        num_wrapped_lines_width = -1;
    }
}

- (NSInteger)generationForLineNumber:(int)lineNum width:(int)width {
    int remainder = 0;
    LineBlock *block = [_lineBlocks blockContainingLineNumber:lineNum
                                                        width:width
                                                    remainder:&remainder];
    return [block generationForLineNumber:remainder width:width];
}

- (NSTimeInterval)timestampForLineNumber:(int)lineNumber width:(int)width {
    int remainder = 0;
    LineBlock *block = [_lineBlocks blockContainingLineNumber:lineNumber
                                                        width:width
                                                    remainder:&remainder];
    return [block timestampForLineNumber:remainder width:width];
}

// Copy a line into the buffer. If the line is shorter than 'width' then only
// the first 'width' characters will be modified.
// 0 <= lineNum < numLinesWithWidth:width
- (int)copyLineToBuffer:(screen_char_t *)buffer
                  width:(int)width
                lineNum:(int)lineNum
           continuation:(screen_char_t *)continuationPtr {
    ITBetaAssert(lineNum >= 0, @"Negative lineNum to copyLineToBuffer");
    int remainder = 0;
    LineBlock *block = [_lineBlocks blockContainingLineNumber:lineNum width:width remainder:&remainder];
    ITBetaAssert(remainder >= 0, @"Negative lineNum BEFORE consuming block_lines");
    if (!block) {
        NSLog(@"Couldn't find line %d", lineNum);
        ITAssertWithMessage(NO, @"Tried to get non-existent line");
        return NO;
    }

    int length;
    int eol;
    screen_char_t continuation;
    const int requestedLine = remainder;
    screen_char_t* p = [block getWrappedLineWithWrapWidth:width
                                                  lineNum:&remainder
                                               lineLength:&length
                                        includesEndOfLine:&eol
                                             continuation:&continuation];
    if (p == nil) {
        ITAssertWithMessage(NO, @"Nil wrapped line %@ for block with width %@", @(requestedLine), @(width));
        return NO;
    }

    if (continuationPtr) {
        *continuationPtr = continuation;
    }
    ITAssertWithMessage(length <= width, @"Length too long");
    memcpy((char*) buffer, (char*) p, length * sizeof(screen_char_t));
    [self extendContinuation:continuation inBuffer:buffer ofLength:length toWidth:width];

    if (requestedLine == 0 && [iTermAdvancedSettingsModel showBlockBoundaries]) {
        for (int i = 0; i < width; i++) {
            buffer[i].code = 'X';
            buffer[i].complexChar = NO;
            buffer[i].image = NO;
            buffer[i].urlCode = 0;
        }
    }
    return eol;
}

- (void)extendContinuation:(screen_char_t)continuation
                  inBuffer:(screen_char_t *)buffer
                  ofLength:(int)length
                   toWidth:(int)width {
    // The LineBlock stores a "continuation" screen_char_t for each line.
    // Clients set this when appending a line to the LineBuffer that has an
    // EOL_HARD. It defines the foreground and background color that null cells
    // added after the end of the line stored in the LineBuffer will have
    // onscreen. We take the continuation and extend it to the end of the
    // buffer, zeroing out the code.
    for (int i = length; i < width; i++) {
        buffer[i] = continuation;
        buffer[i].code = 0;
        buffer[i].complexChar = NO;
    }
}

- (ScreenCharArray *)wrappedLineAtIndex:(int)lineNum
                                  width:(int)width
                           continuation:(screen_char_t *)continuation {
    int remainder = 0;
    LineBlock *block = [_lineBlocks blockContainingLineNumber:lineNum width:width remainder:&remainder];
    if (!block) {
        ITAssertWithMessage(NO, @"Failed to find line %@ with width %@. Cache is: %@", @(lineNum), @(width),
                            [[[[_lineBlocks dumpForCrashlog] dataUsingEncoding:NSUTF8StringEncoding] it_compressedData] it_hexEncoded]);
        return nil;
    }

    int length, eol;
    ScreenCharArray *result = [[[ScreenCharArray alloc] init] autorelease];
    result.line = [block getWrappedLineWithWrapWidth:width
                                             lineNum:&remainder
                                          lineLength:&length
                                   includesEndOfLine:&eol
                                        continuation:continuation];
    if (result.line) {
        result.length = length;
        result.eol = eol;
        ITAssertWithMessage(result.length <= width, @"Length too long");
        return result;
    }

    NSLog(@"Couldn't find line %d", lineNum);
    ITAssertWithMessage(NO, @"Tried to get non-existent line");
    return nil;
}

- (NSArray<ScreenCharArray *> *)wrappedLinesFromIndex:(int)lineNum width:(int)width count:(int)count {
    if (count <= 0) {
        return @[];
    }

    NSMutableArray<ScreenCharArray *> *arrays = [NSMutableArray array];
    [_lineBlocks enumerateLinesInRange:NSMakeRange(lineNum, count)
                                 width:width
                                 block:
     ^(screen_char_t * _Nonnull chars, int length, int eol, screen_char_t continuation, BOOL * _Nonnull stop) {
         ScreenCharArray *lineResult = [[[ScreenCharArray alloc] init] autorelease];
         lineResult.line = chars;
         lineResult.continuation = continuation;
         lineResult.length = length;
         lineResult.eol = eol;
         [arrays addObject:lineResult];
     }];
    return arrays;
}

- (int)numLinesWithWidth:(int)width {
    if (width == 0) {
        return 0;
    }
    return RawNumLines(self, width);
}

- (void)removeLastWrappedLines:(int)numberOfLinesToRemove
                         width:(int)width {
    // Invalidate the cache
    num_wrapped_lines_width = -1;

    int linesToRemoveRemaining = numberOfLinesToRemove;
    while (linesToRemoveRemaining > 0 && _lineBlocks.count > 0) {
        LineBlock *block = _lineBlocks.lastBlock;
        const int numberOfLinesInBlock = [block getNumLinesWithWrapWidth:width];
        if (numberOfLinesInBlock > linesToRemoveRemaining) {
            // Keep part of block
            [block removeLastWrappedLines:linesToRemoveRemaining width:width];
            return;
        }
        // Remove the whole block and try again.
        [_lineBlocks removeLastBlock];
        linesToRemoveRemaining -= numberOfLinesInBlock;
    }
}

- (BOOL)popAndCopyLastLineInto:(screen_char_t*)ptr
                         width:(int)width
             includesEndOfLine:(int*)includesEndOfLine
                     timestamp:(NSTimeInterval *)timestampPtr
                  continuation:(screen_char_t *)continuationPtr
{
    if ([self numLinesWithWidth: width] == 0) {
        return NO;
    }
    num_wrapped_lines_width = -1;

    LineBlock* block = _lineBlocks.lastBlock;

    // If the line is partial the client will want to add a continuation marker so
    // tell him there's no EOL in that case.
    *includesEndOfLine = [block hasPartial] ? EOL_SOFT : EOL_HARD;

    // Pop the last up-to-width chars off the last line.
    int length;
    screen_char_t* temp;
    screen_char_t continuation;
    BOOL ok __attribute__((unused)) =
        [block popLastLineInto:&temp
                    withLength:&length
                     upToWidth:width
                     timestamp:timestampPtr
                  continuation:&continuation];
    if (continuationPtr) {
        *continuationPtr = continuation;
    }
    ITAssertWithMessage(ok, @"Unexpected empty block");
    ITAssertWithMessage(length <= width, @"Length too large");
    ITAssertWithMessage(length >= 0, @"Negative length");

    // Copy into the provided buffer.
    memcpy(ptr, temp, sizeof(screen_char_t) * length);
    [self extendContinuation:continuation inBuffer:ptr ofLength:length toWidth:width];

    // Clean up the block if the whole thing is empty, otherwise another call
    // to this function would not work correctly.
    if ([block isEmpty]) {
        [_lineBlocks removeLastBlock];
    }

#ifdef LOG_MUTATIONS
    NSLog(@"Pop: %@\n", ScreenCharArrayToStringDebug(ptr, width));
#endif
    return YES;
}

NS_INLINE int TotalNumberOfRawLines(LineBuffer *self) {
    return self->_lineBlocks.numberOfRawLines;
}

- (void)setCursor:(int)x {
    LineBlock *block = _lineBlocks.lastBlock;
    if ([block hasPartial]) {
        int last_line_length = [block getRawLineLength: [block numEntries]-1];
        cursor_x = x + last_line_length;
        cursor_rawline = -1;
    } else {
        cursor_x = x;
        cursor_rawline = 0;
    }

    cursor_rawline += TotalNumberOfRawLines(self);
}

- (BOOL)getCursorInLastLineWithWidth:(int)width atX:(int *)x {
    int total_raw_lines = TotalNumberOfRawLines(self);
    if (cursor_rawline == total_raw_lines-1) {
        // The cursor is on the last line in the buffer.
        LineBlock* block = _lineBlocks.lastBlock;
        int last_line_length = [block getRawLineLength: ([block numEntries]-1)];
        screen_char_t* lastRawLine = [block rawLine: ([block numEntries]-1)];
        int num_overflow_lines = [block numberOfFullLinesFromBuffer:lastRawLine length:last_line_length width:width];
#if BETA
        const int legacy_num_overflow_lines = iTermLineBlockNumberOfFullLinesImpl(lastRawLine,
                                                                                  last_line_length,
                                                                                  width,
                                                                                  _mayHaveDoubleWidthCharacter);
        assert(num_overflow_lines == legacy_num_overflow_lines);
#endif

        int min_x = OffsetOfWrappedLine(lastRawLine,
                                        num_overflow_lines,
                                        last_line_length,
                                        width,
                                        _mayHaveDoubleWidthCharacter);
        //int num_overflow_lines = (last_line_length-1) / width;
        //int min_x = num_overflow_lines * width;
        int max_x = min_x + width;  // inclusive because the cursor wraps to the next line on the last line in the buffer
        if (cursor_x >= min_x && cursor_x <= max_x) {
            *x = cursor_x - min_x;
            return YES;
        }
    }
    return NO;
}

- (BOOL)_findPosition:(LineBufferPosition *)start inBlock:(int*)block_num inOffset:(int*)offset {
    LineBlock *block = [_lineBlocks blockContainingPosition:start.absolutePosition - droppedChars
                                                      width:-1
                                                  remainder:offset
                                                blockOffset:NULL
                                                      index:block_num];
    if (!block) {
        return NO;
    }
    return YES;
}

- (int)_blockPosition:(int) block_num {
    return [_lineBlocks rawSpaceUsedInRangeOfBlocks:NSMakeRange(0, block_num)];
}

- (void)prepareToSearchFor:(NSString*)substring
                startingAt:(LineBufferPosition *)start
                   options:(FindOptions)options
                      mode:(iTermFindMode)mode
               withContext:(FindContext*)context {
    DLog(@"Prepare to search for %@", substring);
    context.substring = substring;
    context.options = options;
    if (options & FindOptBackwards) {
        context.dir = -1;
    } else {
        context.dir = 1;
    }
    context.mode = mode;
    int offset = context.offset;
    int absBlockNum = context.absBlockNum;
    if ([self _findPosition:start inBlock:&absBlockNum inOffset:&offset]) {
        context.offset = offset;
        context.absBlockNum = absBlockNum + num_dropped_blocks;
        context.status = Searching;
    } else {
        context.status = NotFound;
    }
    context.results = [NSMutableArray array];
}

- (void)findSubstring:(FindContext*)context stopAt:(LineBufferPosition *)stopPosition {
    NSInteger blockIndex = context.absBlockNum - num_dropped_blocks;
    const NSInteger numBlocks = _lineBlocks.count;  // This avoids involving unsigned integers in comparisons
    if (context.dir > 0) {
        // Search forwards
        if (context.absBlockNum < num_dropped_blocks) {
            // The next block to search was dropped. Skip ahead to the first block.
            // NSLog(@"Next to search was dropped. Skip to start");
            context.absBlockNum = num_dropped_blocks;
        }
        if (blockIndex >= numBlocks) {
            // Got to bottom
            // NSLog(@"Got to bottom");
            context.status = NotFound;
            return;
        }
        if (blockIndex < 0) {
            DLog(@"Negative index %@ in forward search", @(blockIndex));
            context.status = NotFound;
            return;
        }
    } else {
        // Search backwards
        if (blockIndex < 0) {
            // Got to top
            // NSLog(@"Got to top");
            context.status = NotFound;
            return;
        }
        if (blockIndex >= numBlocks) {
            DLog(@"Out of bounds index %@ (>=%@) in backward search", @(blockIndex), @(numBlocks));
            context.status = NotFound;
            return;
        }
    }

    assert(blockIndex >= 0);
    assert(blockIndex < numBlocks);
    LineBlock* block = _lineBlocks[blockIndex];

    if (blockIndex == 0 &&
        context.offset != -1 &&
        context.offset < [block startOffset]) {
        if (context.dir > 0) {
            // Part of the first block has been dropped. Skip ahead to its
            // current beginning.
            context.offset = [block startOffset];
        } else {
            // This block has scrolled off.
            // NSLog(@"offset=%d, block's startOffset=%d. give up", context.offset, [block startOffset]);
            context.status = NotFound;
            return;
        }
    }

    // NSLog(@"search block %d starting at offset %d", context.absBlockNum - num_dropped_blocks, context.offset);

    [block findSubstring:context.substring
                 options:context.options
                    mode:context.mode
                atOffset:context.offset
                 results:context.results
         multipleResults:((context.options & FindMultipleResults) != 0)];
    NSMutableArray* filtered = [NSMutableArray arrayWithCapacity:[context.results count]];
    BOOL haveOutOfRangeResults = NO;
    int blockPosition = [self _blockPosition:context.absBlockNum - num_dropped_blocks];
    const int stopAt = stopPosition.absolutePosition - droppedChars;
    for (ResultRange* range in context.results) {
        range->position += blockPosition;
        if (context.dir * (range->position - stopAt) > 0 ||
            context.dir * (range->position + context.matchLength - stopAt) > 0) {
            // result was outside the range to be searched
            haveOutOfRangeResults = YES;
        } else {
            // Found a good result.
            context.status = Matched;
            [filtered addObject:range];
        }
    }
    context.results = filtered;
    if ([filtered count] == 0 && haveOutOfRangeResults) {
        context.status = NotFound;
    }

    // Prepare to continue searching next block.
    if (context.dir < 0) {
        context.offset = -1;
    } else {
        context.offset = 0;
    }
    context.absBlockNum = context.absBlockNum + context.dir;
}

// Returns an array of XRange values
- (NSArray*)convertPositions:(NSArray *)resultRanges withWidth:(int)width {
    if (width <= 0) {
        return nil;
    }
    // Create sorted array of all positions to convert.
    NSMutableArray* unsortedPositions = [NSMutableArray arrayWithCapacity:[resultRanges count] * 2];
    for (ResultRange* rr in resultRanges) {
        [unsortedPositions addObject:[NSNumber numberWithInt:rr->position]];
        [unsortedPositions addObject:[NSNumber numberWithInt:rr->position + rr->length - 1]];
    }

    // Walk blocks and positions in parallel, converting each position in order. Store in
    // intermediate dict, mapping position->NSPoint(x,y)
    NSArray *positionsArray = [unsortedPositions sortedArrayUsingSelector:@selector(compare:)];
    int i = 0;
    int yoffset = 0;
    int numBlocks = _lineBlocks.count;
    int passed = 0;
    LineBlock *block = _lineBlocks[0];
    int used = [block rawSpaceUsed];
    NSMutableDictionary* intermediate = [NSMutableDictionary dictionaryWithCapacity:[resultRanges count] * 2];
    int prev = -1;
    for (NSNumber* positionNum in positionsArray) {
        int position = [positionNum intValue];
        if (position == prev) {
            continue;
        }
        prev = position;

        // Advance block until it includes this position
        while (position >= passed + used && i < numBlocks) {
            passed += used;
            yoffset += [block getNumLinesWithWrapWidth:width];
            i++;
            if (i < numBlocks) {
                block = _lineBlocks.blocks[i];
                used = [block rawSpaceUsed];
            }
        }
        if (i < numBlocks) {
            int x, y;
            assert(position >= passed);
            assert(position < passed + used);
            assert(used == [block rawSpaceUsed]);
            BOOL isOk = [block convertPosition:position - passed
                                     withWidth:width
                                     wrapOnEOL:YES
                                           toX:&x
                                           toY:&y];
            assert(x < 2000);
            if (isOk) {
                y += yoffset;
                [intermediate setObject:[NSValue valueWithPoint:NSMakePoint(x, y)]
                                 forKey:positionNum];
            } else {
                assert(false);
            }
        }
    }

    // Walk the positions array and populate results by looking up points in intermediate dict.
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:[resultRanges count]];
    for (ResultRange* rr in resultRanges) {
        NSValue *start = [intermediate objectForKey:[NSNumber numberWithInt:rr->position]];
        NSValue *end = [intermediate objectForKey:[NSNumber numberWithInt:rr->position + rr->length - 1]];
        if (start && end) {
            XYRange *xyrange = [[[XYRange alloc] init] autorelease];
            NSPoint startPoint = [start pointValue];
            NSPoint endPoint = [end pointValue];
            xyrange->xStart = startPoint.x;
            xyrange->yStart = startPoint.y;
            xyrange->xEnd = endPoint.x;
            xyrange->yEnd = endPoint.y;
            [result addObject:xyrange];
        }
    }

    return result;
}

- (LineBufferPosition *)positionForCoordinate:(VT100GridCoord)coord
                                        width:(int)width
                                       offset:(int)offset {
    int x = coord.x;
    int y = coord.y;

    int line = y;
    NSInteger index = [_lineBlocks indexOfBlockContainingLineNumber:y width:width remainder:&line];
    if (index == NSNotFound) {
        return nil;
    }

    LineBlock *block = _lineBlocks[index];
    long long absolutePosition = droppedChars + [_lineBlocks rawSpaceUsedInRangeOfBlocks:NSMakeRange(0, index)];

    int pos;
    int yOffset = 0;
    BOOL extends = NO;
    pos = [block getPositionOfLine:&line
                               atX:x
                         withWidth:width
                           yOffset:&yOffset
                           extends:&extends];
    if (pos == 0 && yOffset == 1) {
        // getPositionOfLine:… will set yOffset to 1 when returning the first cell of a raw line to
        // disambiguate the position. That's the right thing to do except for the very first cell
        // in a block, where the position is unambiguous.
        yOffset = 0;
    }
    if (pos < 0) {
        DLog(@"failed to get position of line %@", @(line));
        return nil;
    }

    absolutePosition += pos + offset;
    LineBufferPosition *result = [LineBufferPosition position];
    result.absolutePosition = absolutePosition;
    result.yOffset = yOffset;
    result.extendsToEndOfLine = extends;

    // Make sure position is valid (might not be because of offset).
    BOOL ok;
    [self coordinateForPosition:result
                          width:width
                   extendsRight:YES  // doesn't matter for deciding if the result is valid
                             ok:&ok];
    if (ok) {
        return result;
    } else {
        return nil;
    }
}

- (VT100GridCoord)coordinateForPosition:(LineBufferPosition *)position
                                  width:(int)width
                           extendsRight:(BOOL)extendsRight
                                     ok:(BOOL *)ok {
    if (position.absolutePosition == self.lastPosition.absolutePosition) {
        VT100GridCoord result;
        // If the absolute position is equal to the last position, then
        // numLinesWithWidth: will give the wrapped line number after all
        // trailing empty lines. They all have the same position because they
        // are empty. We need to back up by the number of empty lines and then
        // use position.yOffset to disambiguate.
        result.y = MAX(0, [self numLinesWithWidth:width] - 1 - [_lineBlocks.lastBlock numberOfTrailingEmptyLines]);
        ScreenCharArray *lastLine = [self wrappedLineAtIndex:result.y
                                                       width:width
                                                continuation:NULL];
        result.x = lastLine.length;
        if (position.yOffset > 0) {
            result.x = 0;
            result.y += position.yOffset + 1;
        } else {
            result.x = lastLine.length;
        }
        if (position.extendsToEndOfLine) {
            if (extendsRight) {
                result.x = width - 1;
            }
        }
        if (ok) {
            *ok = YES;
        }
        return result;
    }

    int p;
    int yoffset;
    LineBlock *block = [_lineBlocks blockContainingPosition:position.absolutePosition - droppedChars
                                                      width:width
                                                  remainder:&p
                                                blockOffset:&yoffset
                                                      index:NULL];
    if (!block) {
        if (ok) {
            *ok = NO;
        }
        return VT100GridCoordMake(0, 0);
    }

    int y;
    int x;
    BOOL positionIsValid = [block convertPosition:p
                                        withWidth:width
                                        wrapOnEOL:NO  //  using extendsRight here is wrong because extension happens below
                                              toX:&x
                                              toY:&y];
    if (ok) {
        *ok = positionIsValid;
    }
    if (position.yOffset > 0) {
        if (!position.extendsToEndOfLine) {
            x = 0;
        }
        y += position.yOffset;
    }
    if (position.extendsToEndOfLine) {
        if (extendsRight) {
            x = width - 1;
        } else {
            x = 0;
        }
    }
    return VT100GridCoordMake(x, y + yoffset);
}

- (LineBufferPosition *)firstPosition {
    LineBufferPosition *position = [LineBufferPosition position];
    position.absolutePosition = droppedChars;
    return position;
}

- (LineBufferPosition *)lastPosition {
    LineBufferPosition *position = [LineBufferPosition position];

    position.absolutePosition = droppedChars + [_lineBlocks rawSpaceUsed];

    return position;
}

- (long long)absPositionOfFindContext:(FindContext *)findContext {
    if (findContext.absBlockNum < 0) {
        if (_lineBlocks.count == 0) {
            return 0;
        }
        return findContext.offset + droppedChars + [_lineBlocks rawSpaceUsedInRangeOfBlocks:NSMakeRange(0, _lineBlocks.count)];
    }
    const int numBlocks = MIN(_lineBlocks.count, findContext.absBlockNum - num_dropped_blocks);
    const NSInteger rawSpaceUsed = numBlocks > 0 ? [_lineBlocks rawSpaceUsedInRangeOfBlocks:NSMakeRange(0, numBlocks)] : 0;
    return droppedChars + rawSpaceUsed + findContext.offset;
}

- (int)positionForAbsPosition:(long long)absPosition
{
    absPosition -= droppedChars;
    if (absPosition < 0) {
        return [_lineBlocks[0] startOffset];
    }
    if (absPosition > INT_MAX) {
        absPosition = INT_MAX;
    }
    return (int)absPosition;
}

- (long long)absPositionForPosition:(int)pos
{
    long long absPos = pos;
    return absPos + droppedChars;
}

- (int)absBlockNumberOfAbsPos:(long long)absPos {
    int index;
    LineBlock *block = [_lineBlocks blockContainingPosition:absPos - droppedChars
                                                      width:0
                                                  remainder:NULL
                                                blockOffset:NULL
                                                      index:&index];
    if (!block) {
        return _lineBlocks.count + num_dropped_blocks;
    }
    return index + num_dropped_blocks;
}

- (long long)absPositionOfAbsBlock:(int)absBlockNum {
    if (absBlockNum <= num_dropped_blocks) {
        return droppedChars;
    }
    return droppedChars + [_lineBlocks rawSpaceUsedInRangeOfBlocks:NSMakeRange(0, absBlockNum - num_dropped_blocks)];
}

- (void)storeLocationOfAbsPos:(long long)absPos
                    inContext:(FindContext *)context
{
    context.absBlockNum = [self absBlockNumberOfAbsPos:absPos];
    long long absOffset = [self absPositionOfAbsBlock:context.absBlockNum];
    context.offset = MAX(0, absPos - absOffset);
}

- (LineBuffer *)newAppendOnlyCopy {
    LineBuffer *theCopy = [[LineBuffer alloc] init];
    [theCopy->_lineBlocks release];
    theCopy->_lineBlocks = [_lineBlocks copy];
    LineBlock *lastBlock = _lineBlocks.lastBlock;
    if (lastBlock) {
        [theCopy->_lineBlocks replaceLastBlockWithCopy];
    }
    theCopy->block_size = block_size;
    theCopy->cursor_x = cursor_x;
    theCopy->cursor_rawline = cursor_rawline;
    theCopy->max_lines = max_lines;
    theCopy->num_dropped_blocks = num_dropped_blocks;
    theCopy->num_wrapped_lines_cache = num_wrapped_lines_cache;
    theCopy->num_wrapped_lines_width = num_wrapped_lines_width;
    theCopy->droppedChars = droppedChars;
    theCopy.mayHaveDoubleWidthCharacter = _mayHaveDoubleWidthCharacter;

    return theCopy;
}

- (int)numberOfDroppedBlocks {
    return num_dropped_blocks;
}

- (int)largestAbsoluteBlockNumber {
    return _lineBlocks.count + num_dropped_blocks;
}

// Returns whether we truncated lines.
- (BOOL)encodeBlocks:(id<iTermEncoderAdapter>)encoder
            maxLines:(NSInteger)maxLines {
    __block BOOL truncated = NO;
    __block NSInteger numLines = 0;

    iTermOrderedDictionary<NSString *, LineBlock *> *index =
    [iTermOrderedDictionary byMappingEnumerator:_lineBlocks.blocks.reverseObjectEnumerator
                                          block:^id _Nonnull(NSUInteger index,
                                                             LineBlock *_Nonnull block) {
        DLog(@"Maybe encode block %p with guid %@", block, block.stringUniqueIdentifier);
        return block.stringUniqueIdentifier;
    }];
    [encoder encodeArrayWithKey:kLineBufferBlocksKey
                    identifiers:index.keys
                     generation:iTermGenerationAlwaysEncode
                        options:iTermGraphEncoderArrayOptionsReverse
                          block:^BOOL(id<iTermEncoderAdapter> _Nonnull encoder,
                                      NSInteger i,
                                      NSString * _Nonnull identifier,
                                      BOOL *stop) {
        LineBlock *block = index[identifier];
        DLog(@"Encode %@ with identifier %@ and generation %@", block, identifier, @(block.generation));
        return [encoder encodeDictionaryWithKey:kLineBufferBlockWrapperKey
                                     generation:block.generation
                                          block:^BOOL(id<iTermEncoderAdapter>  _Nonnull encoder) {
            assert(!truncated);
            DLog(@"Really encode block %p with guid %@", block, block.stringUniqueIdentifier);
            [encoder mergeDictionary:block.dictionary]; 
            // This caps the amount of data at a reasonable but arbitrary size.
            numLines += [block getNumLinesWithWrapWidth:80];
            if (numLines >= maxLines) {
                truncated = YES;
                *stop = YES;
            }
            return YES;
        }];
    }];

    return truncated;
}

- (void)encode:(id<iTermEncoderAdapter>)encoder maxLines:(NSInteger)maxLines {
    const BOOL truncated = [self encodeBlocks:encoder maxLines:maxLines];

    [encoder mergeDictionary:
     @{ kLineBufferVersionKey: @(kLineBufferVersion),
        kLineBufferTruncatedKey: @(truncated),
        kLineBufferBlockSizeKey: @(block_size),
        kLineBufferCursorXKey: @(cursor_x),
        kLineBufferCursorRawlineKey: @(cursor_rawline),
        kLineBufferMaxLinesKey: @(max_lines),
        kLineBufferNumDroppedBlocksKey: @(num_dropped_blocks),
        kLineBufferDroppedCharsKey: @(droppedChars),
        kLineBufferMayHaveDWCKey: @(_mayHaveDoubleWidthCharacter) }];
}

- (void)appendMessage:(NSString *)message {
    if (!_lineBlocks.count) {
        [self _addBlockOfSize:message.length];
    }
    screen_char_t defaultBg = { 0 };
    screen_char_t buffer[message.length];
    int len;
    screen_char_t fg = { 0 };
    screen_char_t bg = { 0 };
    fg.foregroundColor = ALTSEM_SYSTEM_MESSAGE;
    fg.backgroundColorMode = ColorModeAlternate;
    bg.backgroundColor = ALTSEM_SYSTEM_MESSAGE;
    bg.backgroundColorMode = ColorModeAlternate;
    StringToScreenChars(message, buffer, fg, bg, &len, NO, NULL, NULL, NO, kUnicodeVersion);
    [self appendLine:buffer
              length:0
             partial:NO
               width:num_wrapped_lines_width > 0 ?: 80
           timestamp:[NSDate timeIntervalSinceReferenceDate]
        continuation:defaultBg];

    [self appendLine:buffer
              length:len
             partial:NO
               width:num_wrapped_lines_width > 0 ?: 80
           timestamp:[NSDate timeIntervalSinceReferenceDate]
        continuation:bg];

    [self appendLine:buffer
              length:0
             partial:NO
               width:num_wrapped_lines_width > 0 ?: 80
           timestamp:[NSDate timeIntervalSinceReferenceDate]
        continuation:defaultBg];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    LineBuffer *theCopy = [[LineBuffer alloc] initWithBlockSize:block_size];

    [theCopy->_lineBlocks release];
    theCopy->_lineBlocks = [_lineBlocks copy];
    theCopy->cursor_x = cursor_x;
    theCopy->cursor_rawline = cursor_rawline;
    theCopy->max_lines = max_lines;
    theCopy->num_dropped_blocks = num_dropped_blocks;
    theCopy->num_wrapped_lines_cache = num_wrapped_lines_cache;
    theCopy->num_wrapped_lines_width = num_wrapped_lines_width;
    theCopy->droppedChars = droppedChars;

    return theCopy;
}

- (int)numBlocksAtEndToGetMinimumLines:(int)minLines width:(int)width {
    int numBlocks = 0;
    int lines = 0;
    for (LineBlock *block in _lineBlocks.blocks.reverseObjectEnumerator) {
        lines += [block getNumLinesWithWrapWidth:width];
        ++numBlocks;
        if (lines > minLines) {
            break;
        }
    }
    return numBlocks;
}

- (long long)numCharsInRangeOfBlocks:(NSRange)range {
    long long n = 0;
    for (int i = 0; i < range.length; i++) {
        NSUInteger j = range.location + i;
        n += [_lineBlocks[j] numberOfCharacters];
    }
    return n;
}

- (LineBuffer *)appendOnlyCopyWithMinimumLines:(int)minLines atWidth:(int)width {
    // Calculate how many blocks to keep.
    const int numBlocks = [self numBlocksAtEndToGetMinimumLines:minLines width:width];
    const int totalBlocks = _lineBlocks.count;
    const int numDroppedBlocks = totalBlocks - numBlocks;

    // Make a copy of the whole thing (cheap)
    LineBuffer *theCopy = [[self newAppendOnlyCopy] autorelease];

    // Remove the blocks we don't need.
    [theCopy->_lineBlocks removeFirstBlocks:numDroppedBlocks];

    // Update stats and nuke cache.
    theCopy->num_dropped_blocks += numDroppedBlocks;
    theCopy->num_wrapped_lines_width = -1;
    theCopy->droppedChars += [self numCharsInRangeOfBlocks:NSMakeRange(0, numDroppedBlocks)];

    return theCopy;
}

- (int)numberOfWrappedLinesWithWidth:(int)width {
    return [_lineBlocks numberOfWrappedLinesForWidth:width];
}

- (void)beginResizing {
    assert(!_lineBlocks.resizing);
    _lineBlocks.resizing = YES;

    // Just a sanity check, not a real limitation.
    dispatch_async(dispatch_get_main_queue(), ^{
        assert(!_lineBlocks.resizing);
    });
}

- (void)endResizing {
    assert(_lineBlocks.resizing);
    _lineBlocks.resizing = NO;
}

- (void)setPartial:(BOOL)partial {
    [_lineBlocks.lastBlock setPartial:partial];
}

@end
