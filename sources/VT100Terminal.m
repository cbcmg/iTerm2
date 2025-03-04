#import "VT100Terminal.h"
#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermParser.h"
#import "iTermURLStore.h"
#import "NSColor+iTerm.h"
#import "NSData+iTerm.h"
#import "NSDictionary+iTerm.h"
#import "NSObject+iTerm.h"
#import "NSStringITerm.h"
#import "NSURL+iTerm.h"
#import "VT100DCSParser.h"
#import "VT100Parser.h"
#import <apr-1/apr_base64.h>  // for xterm's base64 decoding (paste64)
#include <term.h>

NSString *const kGraphicRenditionBoldKey = @"Bold";
NSString *const kGraphicRenditionBlinkKey = @"Blink";
NSString *const kGraphicRenditionUnderlineKey = @"Underline";
NSString *const kGraphicRenditionStrikethroughKey = @"Strikethrough";
NSString *const kGraphicRenditionUnderlineStyle = @"Underline Style";
NSString *const kGraphicRenditionReversedKey = @"Reversed";
NSString *const kGraphicRenditionFaintKey = @"Faint";
NSString *const kGraphicRenditionItalicKey = @"Italic";
NSString *const kGraphicRenditionForegroundColorCodeKey = @"FG Color/Red";
NSString *const kGraphicRenditionForegroundGreenKey = @"FG Green";
NSString *const kGraphicRenditionForegroundBlueKey = @"FG Blue";
NSString *const kGraphicRenditionForegroundModeKey = @"FG Mode";
NSString *const kGraphicRenditionBackgroundColorCodeKey = @"BG Color/Red";
NSString *const kGraphicRenditionBackgroundGreenKey = @"BG Green";
NSString *const kGraphicRenditionBackgroundBlueKey = @"BG Blue";
NSString *const kGraphicRenditionBackgroundModeKey = @"BG Mode";

NSString *const kSavedCursorPositionKey = @"Position";
NSString *const kSavedCursorCharsetKey = @"Charset";
NSString *const kSavedCursorLineDrawingArrayKey = @"Line Drawing Flags";
NSString *const kSavedCursorGraphicRenditionKey = @"Graphic Rendition";
NSString *const kSavedCursorOriginKey = @"Origin";
NSString *const kSavedCursorWraparoundKey = @"Wraparound";
NSString *const kSavedCursorUnicodeVersion = @"Unicode Version";

NSString *const kTerminalStateTermTypeKey = @"Term Type";
NSString *const kTerminalStateAnswerBackStringKey = @"Answerback String";
NSString *const kTerminalStateStringEncodingKey = @"String Encoding";
NSString *const kTerminalStateCanonicalEncodingKey = @"Canonical String Encoding";
NSString *const kTerminalStateReportFocusKey = @"Report Focus";
NSString *const kTerminalStateReverseVideoKey = @"Reverse Video";
NSString *const kTerminalStateOriginModeKey = @"Origin Mode";
NSString *const kTerminalStateMoreFixKey = @"More-Fix";
NSString *const kTerminalStateWraparoundModeKey = @"Wraparound Mode";
NSString *const kTerminalStateReverseWraparoundModeKey = @"Reverse Wraparound Mode";
NSString *const kTerminalStateIsAnsiKey = @"Is ANSI";
NSString *const kTerminalStateAutorepeatModeKey = @"Autorepeat Mode";
NSString *const kTerminalStateInsertModeKey = @"Insert Mode";
NSString *const kTerminalStateSendReceiveModeKey = @"Send/Receive Mode";
NSString *const kTerminalStateCharsetKey = @"Charset";
NSString *const kTerminalStateMouseModeKey = @"Mouse Mode";
NSString *const kTerminalStatePreviousMouseModeKey = @"Previous Mouse Mode";
NSString *const kTerminalStateMouseFormatKey = @"Mouse Format";
NSString *const kTerminalStateCursorModeKey = @"Cursor Mode";
NSString *const kTerminalStateKeypadModeKey = @"Keypad Mode";
NSString *const kTerminalStateAllowKeypadModeKey = @"Allow Keypad Mode";
NSString *const kTerminalStateAllowPasteBracketing = @"Allow Paste Bracketing";
NSString *const kTerminalStateBracketedPasteModeKey = @"Bracketed Paste Mode";
NSString *const kTerminalStateAnsiModeKey = @"ANSI Mode";
NSString *const kTerminalStateNumLockKey = @"Numlock";
NSString *const kTerminalStateGraphicRenditionKey = @"Graphic Rendition";
NSString *const kTerminalStateMainSavedCursorKey = @"Main Saved Cursor";
NSString *const kTerminalStateAltSavedCursorKey = @"Alt Saved Cursor";
NSString *const kTerminalStateAllowColumnModeKey = @"Allow Column Mode";
NSString *const kTerminalStateColumnModeKey = @"Column Mode";
NSString *const kTerminalStateDisableSMCUPAndRMCUPKey = @"Disable Alt Screen";
NSString *const kTerminalStateSoftAlternateScreenModeKey = @"Soft Alternate Screen Mode";
NSString *const kTerminalStateInCommandKey = @"In Command";
NSString *const kTerminalStateUnicodeVersionStack = @"Unicode Version Stack";
NSString *const kTerminalStateURL = @"URL";
NSString *const kTerminalStateURLParams = @"URL Params";
NSString *const kTerminalStateReportKeyUp = @"Report Key Up";
NSString *const kTerminalStateMetaSendsEscape = @"Meta Sends Escape";
NSString *const kTerminalStateSendModifiers = @"Send Modifiers";
NSString *const kTerminalStateKeyReportingModeStack = @"Key Reporting Mode Stack";

@interface VT100Terminal ()
@property(nonatomic, assign) BOOL reverseVideo;
@property(nonatomic, assign) BOOL originMode;
@property(nonatomic, assign) BOOL moreFix;
@property(nonatomic, assign) BOOL isAnsi;
@property(nonatomic, assign) BOOL autorepeatMode;
@property(nonatomic, assign) int charset;
@property(nonatomic, assign) BOOL allowColumnMode;
@property(nonatomic, assign) BOOL columnMode;  // YES=132 Column, NO=80 Column
@property(nonatomic, assign) BOOL disableSmcupRmcup;
@property(nonatomic, retain) NSURL *url;
@property(nonatomic, retain) NSString *urlParams;

// A write-only property, at the moment. TODO: What should this do?
@property(nonatomic, assign) BOOL strictAnsiMode;

@end

#define NUM_CHARSETS 4

typedef struct {
    VT100GridCoord position;
    int charset;
    BOOL lineDrawing[NUM_CHARSETS];
    VT100GraphicRendition graphicRendition;
    BOOL origin;
    BOOL wraparound;
    NSInteger unicodeVersion;
} VT100SavedCursor;

@interface VT100Terminal()
@property (nonatomic, strong, readwrite) NSMutableArray<NSNumber *> *sendModifiers;
@end

@implementation VT100Terminal {
    // In FinalTerm command mode (user is at the prompt typing a command).
    BOOL inCommand_;

    id<VT100TerminalDelegate> delegate_;

    BOOL ansiMode_;         // YES=ANSI, NO=VT52
    BOOL numLock_;           // YES=ON, NO=OFF, default=YES;

    VT100SavedCursor mainSavedCursor_;
    VT100SavedCursor altSavedCursor_;

    NSMutableArray *_unicodeVersionStack;

    // Code for the current hypertext link, or 0 if not in a hypertext link.
    unsigned short _currentURLCode;

    BOOL _softAlternateScreenMode;
    NSMutableArray<NSNumber *> *_keyReportingModeStack;
}

@synthesize delegate = delegate_;
@synthesize receivingFile = receivingFile_;
@synthesize graphicRendition = graphicRendition_;

#define DEL  0x7f

// character attributes
#define VT100CHARATTR_ALLOFF           0
#define VT100CHARATTR_BOLD             1
#define VT100CHARATTR_FAINT            2
#define VT100CHARATTR_ITALIC           3
#define VT100CHARATTR_UNDERLINE        4
#define VT100CHARATTR_BLINK            5
#define VT100CHARATTR_REVERSE          7
#define VT100CHARATTR_STRIKETHROUGH    9

// xterm additions
#define VT100CHARATTR_NORMAL            22
#define VT100CHARATTR_NOT_ITALIC        23
#define VT100CHARATTR_NOT_UNDERLINE     24
#define VT100CHARATTR_STEADY            25
#define VT100CHARATTR_POSITIVE          27
#define VT100CHARATTR_NOT_STRIKETHROUGH 29

typedef enum {
    COLORCODE_BLACK = 0,
    COLORCODE_RED = 1,
    COLORCODE_GREEN = 2,
    COLORCODE_YELLOW = 3,
    COLORCODE_BLUE = 4,
    COLORCODE_MAGENTA = 5,
    COLORCODE_WATER = 6,
    COLORCODE_WHITE = 7,
    COLORCODE_256 = 8,
} colorCode;

// Color constants
// Color codes for 8-color mode. Black and white are the limits; other codes can be constructed
// similarly.
#define VT100CHARATTR_FG_BASE  30
#define VT100CHARATTR_BG_BASE  40

#define VT100CHARATTR_FG_BLACK     (VT100CHARATTR_FG_BASE + COLORCODE_BLACK)
#define VT100CHARATTR_FG_WHITE     (VT100CHARATTR_FG_BASE + COLORCODE_WHITE)
#define VT100CHARATTR_FG_256       (VT100CHARATTR_FG_BASE + COLORCODE_256)
#define VT100CHARATTR_FG_DEFAULT   (VT100CHARATTR_FG_BASE + 9)

#define VT100CHARATTR_BG_BLACK     (VT100CHARATTR_BG_BASE + COLORCODE_BLACK)
#define VT100CHARATTR_BG_WHITE     (VT100CHARATTR_BG_BASE + COLORCODE_WHITE)
#define VT100CHARATTR_BG_256       (VT100CHARATTR_BG_BASE + COLORCODE_256)
#define VT100CHARATTR_BG_DEFAULT   (VT100CHARATTR_BG_BASE + 9)

// Color codes for 16-color mode. Black and white are the limits; other codes can be constructed
// similarly.
#define VT100CHARATTR_FG_HI_BASE  90
#define VT100CHARATTR_BG_HI_BASE  100

#define VT100CHARATTR_FG_HI_BLACK     (VT100CHARATTR_FG_HI_BASE + COLORCODE_BLACK)
#define VT100CHARATTR_FG_HI_WHITE     (VT100CHARATTR_FG_HI_BASE + COLORCODE_WHITE)

#define VT100CHARATTR_BG_HI_BLACK     (VT100CHARATTR_BG_HI_BASE + COLORCODE_BLACK)
#define VT100CHARATTR_BG_HI_WHITE     (VT100CHARATTR_BG_HI_BASE + COLORCODE_WHITE)

// Prevents runaway memory usage
static const int kMaxScreenColumns = 4096;
static const int kMaxScreenRows = 4096;

#pragma mark - Instance methods

- (instancetype)init {
    self = [super init];
    if (self) {
        _output = [[VT100Output alloc] init];
        _encoding = _canonicalEncoding = NSASCIIStringEncoding;
        _parser = [[VT100Parser alloc] init];
        _parser.encoding = _encoding;

        _wraparoundMode = YES;
        _reverseWraparoundMode = NO;
        _autorepeatMode = YES;
        graphicRendition_.fgColorCode = ALTSEM_DEFAULT;
        graphicRendition_.fgColorMode = ColorModeAlternate;
        graphicRendition_.bgColorCode = ALTSEM_DEFAULT;
        graphicRendition_.bgColorMode = ColorModeAlternate;
        _mouseMode = MOUSE_REPORTING_NONE;
        _previousMouseMode = MOUSE_REPORTING_NORMAL;
        _mouseFormat = MOUSE_FORMAT_XTERM;

        _allowKeypadMode = YES;
        _allowPasteBracketing = YES;
        _sendModifiers = [@[ @-1, @-1, @-1, @-1, @-1 ] mutableCopy];
        _keyReportingModeStack = [[NSMutableArray alloc] init];
        numLock_ = YES;
        [self saveCursor];  // initialize save area
        _unicodeVersionStack = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_output release];
    [_parser release];
    [_termType release];
    [_answerBackString release];
    [_unicodeVersionStack release];
    [_url release];
    [_urlParams release];
    [_sendModifiers release];
    [_keyReportingModeStack release];

    [super dealloc];
}

- (void)stopReceivingFile {
    DLog(@"%@", [NSThread callStackSymbols]);
    receivingFile_ = NO;
}

- (void)setEncoding:(NSStringEncoding)encoding {
    [self setEncoding:encoding canonical:YES];
}

- (void)setEncoding:(NSStringEncoding)encoding canonical:(BOOL)canonical {
    if (canonical) {
        _canonicalEncoding = encoding;
    }
    _encoding = encoding;
    _parser.encoding = encoding;
}

- (void)setTermType:(NSString *)termtype {
    DLog(@"setTermType:%@", termtype);
    [_termType autorelease];
    _termType = [termtype copy];

    self.allowKeypadMode = [_termType rangeOfString:@"xterm"].location != NSNotFound;

    int r;

    // NOTE: This seems to cause a memory leak. The setter for termTypeIsValid (below) has the
    // side effect of copying various curses strings, and it depends on this. When I redo output,
    // fix this disaster.
    setupterm((char *)[_termType UTF8String], fileno(stdout), &r);
    if (r != 1) {
        DLog(@"Terminal type %s is not defined.", [_termType UTF8String]);
    }
    _output.termTypeIsValid = (r == 1);
    if ([termtype isEqualToString:@"VT100"]) {
        _output.vtLevel = VT100EmulationLevel100;
    } else {
        _output.vtLevel = VT100EmulationLevel200;
    }
    self.isAnsi = [_termType rangeOfString:@"ANSI"
                                   options:NSCaseInsensitiveSearch | NSAnchoredSearch ].location !=  NSNotFound;
    [delegate_ terminalTypeDidChange];
}

- (void)setAnswerBackString:(NSString *)s {
    s = [s stringByExpandingVimSpecialCharacters];
    _answerBackString = [s copy];
}

- (void)setForeground24BitColor:(NSColor *)color {
    graphicRendition_.fgColorCode = color.redComponent * 255.0;
    graphicRendition_.fgGreen = color.greenComponent * 255.0;
    graphicRendition_.fgBlue = color.blueComponent * 255.0;
    graphicRendition_.fgColorMode = ColorMode24bit;
}

- (void)setForegroundColor:(int)fgColorCode alternateSemantics:(BOOL)altsem
{
    graphicRendition_.fgColorCode = fgColorCode;
    graphicRendition_.fgColorMode = (altsem ? ColorModeAlternate : ColorModeNormal);
}

- (void)setBackgroundColor:(int)bgColorCode alternateSemantics:(BOOL)altsem
{
    graphicRendition_.bgColorCode = bgColorCode;
    graphicRendition_.bgColorMode = (altsem ? ColorModeAlternate : ColorModeNormal);
}

- (void)setSoftAlternateScreenMode:(BOOL)softAlternateScreenMode {
    if (softAlternateScreenMode == _softAlternateScreenMode) {
        return;
    }
    _softAlternateScreenMode = softAlternateScreenMode;
    [self.delegate terminalSoftAlternateScreenModeDidChange];
}

- (void)resetCharset {
    _charset = 0;
    for (int i = 0; i < NUM_CHARSETS; i++) {
        [delegate_ terminalSetCharset:i toLineDrawingMode:NO];
    }
}

- (void)commonReset {
    DLog(@"TERMINAL RESET");
    self.cursorMode = NO;
    _reverseVideo = NO;
    _originMode = NO;
    _moreFix = NO;
    self.wraparoundMode = YES;
    self.reverseWraparoundMode = NO;
    self.autorepeatMode = YES;
    self.keypadMode = NO;
    self.reportKeyUp = NO;
    self.metaSendsEscape = NO;
    self.insertMode = NO;
    self.sendReceiveMode = NO;
    self.bracketedPasteMode = NO;
    _charset = 0;
    [self resetGraphicRendition];
    self.mouseMode = MOUSE_REPORTING_NONE;
    self.mouseFormat = MOUSE_FORMAT_XTERM;
    [self saveCursor];  // reset saved text attributes
    [delegate_ terminalMouseModeDidChangeTo:_mouseMode];
    [delegate_ terminalSetUseColumnScrollRegion:NO];
    self.reportFocus = NO;

    self.strictAnsiMode = NO;
    self.allowColumnMode = NO;
    receivingFile_ = NO;
    _copyingToPasteboard = NO;
    _encoding = _canonicalEncoding;
    _parser.encoding = _canonicalEncoding;
    for (int i = 0; i < NUM_CHARSETS; i++) {
        mainSavedCursor_.lineDrawing[i] = NO;
        altSavedCursor_.lineDrawing[i] = NO;
    }
    [_keyReportingModeStack removeAllObjects];
    [self resetSavedCursorPositions];
    [delegate_ terminalShowPrimaryBuffer];
    self.softAlternateScreenMode = NO;
    [self resetSendModifiersWithSideEffects:NO];
    [self.delegate terminalDidChangeSendModifiers];
}

- (void)resetSendModifiersWithSideEffects:(BOOL)sideEffects {
    for (int i = 0; i < NUM_MODIFIABLE_RESOURCES; i++) {
        _sendModifiers[i] = @-1;
    }
    if (sideEffects) {
        [self.delegate terminalDidChangeSendModifiers];
    }
}

- (void)gentleReset {
    [self commonReset];
    [delegate_ terminalSetCursorVisible:YES];
}

- (void)resetByUserRequest:(BOOL)userInitiated {
    [self resetAllowingResize:YES preservePrompt:userInitiated resetParser:userInitiated modifyContent:YES];
}

- (void)resetForRelaunch {
    [self resetAllowingResize:NO preservePrompt:NO resetParser:YES modifyContent:NO];
}

- (void)resetAllowingResize:(BOOL)canResize
             preservePrompt:(BOOL)preservePrompt
                resetParser:(BOOL)resetParser
              modifyContent:(BOOL)modifyContent {
    if (canResize && _columnMode) {
        [delegate_ terminalSetWidth:80];
    }
    self.columnMode = NO;
    [self commonReset];
    if (resetParser) {
        [_parser reset];
    }
    [delegate_ terminalResetPreservingPrompt:preservePrompt modifyContent:modifyContent];
}

- (void)resetForTmuxUnpause {
    [self resetAllowingResize:NO preservePrompt:NO resetParser:YES modifyContent:YES];
}

- (void)setWraparoundMode:(BOOL)mode {
    if (mode != _wraparoundMode) {
        _wraparoundMode = mode;
        [delegate_ terminalWraparoundModeDidChangeTo:mode];
    }
}

- (void)setCursorMode:(BOOL)cursorMode {
    _cursorMode = cursorMode;
    _output.cursorMode = cursorMode;
}

- (void)setMouseFormat:(MouseFormat)mouseFormat {
    _mouseFormat = mouseFormat;
    _output.mouseFormat = mouseFormat;
}

- (void)setKeypadMode:(BOOL)mode {
    [self forceSetKeypadMode:(mode && self.allowKeypadMode)];
}

- (void)forceSetKeypadMode:(BOOL)mode {
    _keypadMode = mode;
    _output.keypadMode = _keypadMode;
}

- (void)setAllowKeypadMode:(BOOL)allow {
    _allowKeypadMode = allow;
    if (!allow) {
        self.keypadMode = NO;
    }
}

- (void)setReportKeyUp:(BOOL)reportKeyUp {
    if (reportKeyUp == _reportKeyUp) {
        return;
    }
    _reportKeyUp = reportKeyUp;
    [self.delegate terminalReportKeyUpDidChange:reportKeyUp];
}

- (VT100TerminalKeyReportingFlags)keyReportingFlags {
    return _keyReportingModeStack.lastObject.intValue;
}

- (screen_char_t)foregroundColorCode
{
    screen_char_t result = { 0 };
    if (graphicRendition_.reversed) {
        if (graphicRendition_.bgColorMode == ColorModeAlternate &&
            graphicRendition_.bgColorCode == ALTSEM_DEFAULT) {
            result.foregroundColor = ALTSEM_REVERSED_DEFAULT;
        } else {
            result.foregroundColor = graphicRendition_.bgColorCode;
        }
        result.fgGreen = graphicRendition_.bgGreen;
        result.fgBlue = graphicRendition_.bgBlue;
        result.foregroundColorMode = graphicRendition_.bgColorMode;
    } else {
        result.foregroundColor = graphicRendition_.fgColorCode;
        result.fgGreen = graphicRendition_.fgGreen;
        result.fgBlue = graphicRendition_.fgBlue;
        result.foregroundColorMode = graphicRendition_.fgColorMode;
    }
    result.bold = graphicRendition_.bold;
    result.faint = graphicRendition_.faint;
    result.italic = graphicRendition_.italic;
    result.underline = graphicRendition_.underline;
    result.strikethrough = graphicRendition_.strikethrough;
    result.underlineStyle = graphicRendition_.underlineStyle;
    result.blink = graphicRendition_.blink;
    result.image = NO;
    result.urlCode = _currentURLCode;
    return result;
}

- (screen_char_t)backgroundColorCode
{
    screen_char_t result = { 0 };
    if (graphicRendition_.reversed) {
        if (graphicRendition_.fgColorMode == ColorModeAlternate &&
            graphicRendition_.fgColorCode == ALTSEM_DEFAULT) {
            result.backgroundColor = ALTSEM_REVERSED_DEFAULT;
        } else {
            result.backgroundColor = graphicRendition_.fgColorCode;
        }
        result.bgGreen = graphicRendition_.fgGreen;
        result.bgBlue = graphicRendition_.fgBlue;
        result.backgroundColorMode = graphicRendition_.fgColorMode;
    } else {
        result.backgroundColor = graphicRendition_.bgColorCode;
        result.bgGreen = graphicRendition_.bgGreen;
        result.bgBlue = graphicRendition_.bgBlue;
        result.backgroundColorMode = graphicRendition_.bgColorMode;
    }
    return result;
}

- (screen_char_t)foregroundColorCodeReal
{
    screen_char_t result = { 0 };
    result.foregroundColor = graphicRendition_.fgColorCode;
    result.fgGreen = graphicRendition_.fgGreen;
    result.fgBlue = graphicRendition_.fgBlue;
    result.foregroundColorMode = graphicRendition_.fgColorMode;
    result.bold = graphicRendition_.bold;
    result.faint = graphicRendition_.faint;
    result.italic = graphicRendition_.italic;
    result.underline = graphicRendition_.underline;
    result.strikethrough = graphicRendition_.strikethrough;
    result.underlineStyle = graphicRendition_.underlineStyle;
    result.blink = graphicRendition_.blink;
    result.urlCode = _currentURLCode;
    return result;
}

- (screen_char_t)backgroundColorCodeReal
{
    screen_char_t result = { 0 };
    result.backgroundColor = graphicRendition_.bgColorCode;
    result.bgGreen = graphicRendition_.bgGreen;
    result.bgBlue = graphicRendition_.bgBlue;
    result.backgroundColorMode = graphicRendition_.bgColorMode;
    return result;
}

- (void)setInsertMode:(BOOL)mode
{
    if (_insertMode != mode) {
        _insertMode = mode;
        [delegate_ terminalInsertModeDidChangeTo:mode];
    }
}

- (void)executeDecSetReset:(VT100Token *)token {
    assert(token->type == VT100CSI_DECSET ||
           token->type == VT100CSI_DECRST);
    BOOL mode = (token->type == VT100CSI_DECSET);

    for (int i = 0; i < token.csi->count; i++) {
        switch (token.csi->p[i]) {
            case -1:
                // This was removed by translating from screen -> xterm for tmux mode.
                break;
            case 1:
                self.cursorMode = mode;
                break;
            case 2:
                ansiMode_ = mode;
                break;
            case 3:
                if (self.allowColumnMode) {
                    self.columnMode = mode;
                    [delegate_ terminalSetWidth:(self.columnMode ? 132 : 80)];
                }
                break;
            case 4:
                // Smooth vs jump scrolling. Not supported.
                break;
            case 5:
                self.reverseVideo = mode;
                [delegate_ terminalNeedsRedraw];
                break;
            case 6:
                self.originMode = mode;
                [delegate_ terminalMoveCursorToX:1 y:1];
                break;
            case 7:
                self.wraparoundMode = mode;
                break;
            case 8:
                self.autorepeatMode = mode;
                break;
            case 9:
                // TODO: This should send mouse x&y on button press.
                break;
            case 20:
                // This used to be the setter for "line mode", but it wasn't used and it's not
                // supported by xterm. Seemed to have something to do with CR vs LF.
                break;
            case 25:
                [delegate_ terminalSetCursorVisible:mode];
                break;
            case 40:
                self.allowColumnMode = mode;
                break;
            case 41:
                self.moreFix = mode;
                break;
            case 45:
                self.reverseWraparoundMode = mode;
                break;
            case 47:
                // alternate screen buffer mode
                if (!self.disableSmcupRmcup) {
                    if (mode) {
                        int x = [delegate_ terminalCursorX];
                        int y = [delegate_ terminalCursorY];
                        [delegate_ terminalShowAltBuffer];
                        [delegate_ terminalSetCursorX:x];
                        [delegate_ terminalSetCursorY:y];
                    } else {
                        int x = [delegate_ terminalCursorX];
                        int y = [delegate_ terminalCursorY];
                        [delegate_ terminalShowPrimaryBuffer];
                        [delegate_ terminalSetCursorX:x];
                        [delegate_ terminalSetCursorY:y];
                    }
                }
                self.softAlternateScreenMode = mode;
                break;

            case 69:
                [delegate_ terminalSetUseColumnScrollRegion:mode];
                break;

            case 1000:
            // case 1001:
            // TODO: MOUSE_REPORTING_HIGHLIGHT not implemented.
            case 1002:
            case 1003:
                if (mode) {
                    self.mouseMode = token.csi->p[i] - 1000;
                } else {
                    self.mouseMode = MOUSE_REPORTING_NONE;
                }
                [delegate_ terminalMouseModeDidChangeTo:_mouseMode];
                break;
            case 1004:
                self.reportFocus = mode && [delegate_ terminalFocusReportingAllowed];
                break;

            case 1005:
                if (mode) {
                    self.mouseFormat = MOUSE_FORMAT_XTERM_EXT;
                } else {
                    self.mouseFormat = MOUSE_FORMAT_XTERM;
                }
                break;


            case 1006:
                if (mode) {
                    self.mouseFormat = MOUSE_FORMAT_SGR;
                } else {
                    self.mouseFormat = MOUSE_FORMAT_XTERM;
                }
                break;

            case 1015:
                if (mode) {
                    self.mouseFormat = MOUSE_FORMAT_URXVT;
                } else {
                    self.mouseFormat = MOUSE_FORMAT_XTERM;
                }
                break;

            case 1036:
                self.metaSendsEscape = mode;
                break;

            case 1337:
                self.reportKeyUp = mode;
                break;
                
            case 1049:
                // From the xterm release log:
                // Implement new escape sequence, private mode 1049, which combines
                // the switch to/from alternate screen mode with screen clearing and
                // cursor save/restore.  Unlike the existing escape sequence, this
                // clears the alternate screen when switching to it rather than when
                // switching to the normal screen, thus retaining the alternate screen
                // contents for select/paste operations.
                if (!self.disableSmcupRmcup) {
                    if (mode) {
                        [self saveCursor];
                        [delegate_ terminalShowAltBuffer];
                        [delegate_ terminalClearScreen];
                        [delegate_ terminalMoveCursorToX:1 y:1];
                    } else {
                        [delegate_ terminalShowPrimaryBuffer];
                        [self restoreCursor];
                    }
                }
                self.softAlternateScreenMode = mode;
                break;

            case 2004:
                // Set bracketed paste mode
                [self setBracketedPasteMode:mode && self.allowPasteBracketing withSideEffects:YES];
                break;
        }
    }
}

- (void)resetGraphicRendition {
    memset(&graphicRendition_, 0, sizeof(graphicRendition_));
}

- (void)executeSGR:(VT100Token *)token {
    assert(token->type == VT100CSI_SGR);
    if (token.csi->count == 0) {
        [self resetGraphicRendition];
    } else {
        int i;
        for (i = 0; i < token.csi->count; ++i) {
            int n = token.csi->p[i];
            switch (n) {
                case VT100CHARATTR_ALLOFF:
                    [self resetGraphicRendition];
                    break;
                case VT100CHARATTR_BOLD:
                    graphicRendition_.bold = YES;
                    break;
                case VT100CHARATTR_FAINT:
                    graphicRendition_.faint = YES;
                    break;
                case VT100CHARATTR_NORMAL:
                    graphicRendition_.faint = graphicRendition_.bold = NO;
                    break;
                case VT100CHARATTR_ITALIC:
                    graphicRendition_.italic = YES;
                    break;
                case VT100CHARATTR_NOT_ITALIC:
                    graphicRendition_.italic = NO;
                    break;
                case VT100CHARATTR_UNDERLINE: {
                    graphicRendition_.underline = YES;
                    int subs[VT100CSISUBPARAM_MAX];
                    const int numberOfSubparameters = iTermParserGetAllCSISubparametersForParameter(token.csi, i, subs);
                    if (numberOfSubparameters > 0) {
                        switch (subs[0]) {
                            case 0:
                                graphicRendition_.underline = NO;
                                break;
                            case 1:
                                graphicRendition_.underlineStyle = VT100UnderlineStyleSingle;
                                break;
                            case 3:
                                graphicRendition_.underlineStyle = VT100UnderlineStyleCurly;
                                break;
                        }
                    }
                    break;
                }
                case VT100CHARATTR_NOT_UNDERLINE:
                    graphicRendition_.underline = NO;
                    break;
                case VT100CHARATTR_STRIKETHROUGH:
                    graphicRendition_.strikethrough = YES;
                    break;
                case VT100CHARATTR_NOT_STRIKETHROUGH:
                    graphicRendition_.strikethrough = NO;
                    break;
                case VT100CHARATTR_BLINK:
                    graphicRendition_.blink = YES;
                    break;
                case VT100CHARATTR_STEADY:
                    graphicRendition_.blink = NO;
                    break;
                case VT100CHARATTR_REVERSE:
                    graphicRendition_.reversed = YES;
                    break;
                case VT100CHARATTR_POSITIVE:
                    graphicRendition_.reversed = NO;
                    break;
                case VT100CHARATTR_FG_DEFAULT:
                    graphicRendition_.fgColorCode = ALTSEM_DEFAULT;
                    graphicRendition_.fgGreen = 0;
                    graphicRendition_.fgBlue = 0;
                    graphicRendition_.fgColorMode = ColorModeAlternate;
                    break;
                case VT100CHARATTR_BG_DEFAULT:
                    graphicRendition_.bgColorCode = ALTSEM_DEFAULT;
                    graphicRendition_.bgGreen = 0;
                    graphicRendition_.bgBlue = 0;
                    graphicRendition_.bgColorMode = ColorModeAlternate;
                    break;
                case VT100CHARATTR_FG_256: {
                    // The actual spec for this is called ITU T.416-199303
                    // You can download it for free! If you prefer to spend money, ISO/IEC 8613-6
                    // is supposedly the same thing.
                    //
                    // Here's a sad story about CSI 38:2, which is used to do 24-bit color.
                    //
                    // Lots of terminal emulators, iTerm2 included, misunderstood the spec. That's
                    // easy to understand if you read it, which I can't recommend doing unless
                    // you're looking for inspiration for your next Bulwer-Lytton Fiction Contest
                    // entry.
                    //
                    // See issue 6377 for more context.
                    //
                    // Ignoring color types we don't support like CMYK, the spec says to do this:
                    // CSI 38:2:[color space]:[red]:[green]:[blue]:[unused]:[tolerance]:[tolerance colorspace]
                    //
                    // Everything after [blue] is optional. Values are decimal numbers in 0...255.
                    //
                    // Unfortunately, what was implemented for a long time was this:
                    // CSI 38:2:[red]:[green]:[blue]:[unused]:[tolerance]:[tolerance colorspace]
                    //
                    // And for xterm compatibility, the following was also accepted:
                    // CSI 38;2;[red];[green];[blue]
                    //
                    // The New Order
                    // -------------
                    // Tolerance never did anything, so we'll accept this non-standards compliant
                    // code, which people use:
                    // CSI 38:2:[red]:[green]:[blue]
                    //
                    // As well as the following forms:
                    // CSI 38:2:[colorspace]:[red]:[green]:[blue]
                    // CSI 38:2:[colorspace]:[red]:[green]:[blue]:<one or more additional colon-delimited arguments, all ignored>
                    // CSI 38;2;[red];[green];[blue]   // Notice semicolons in place of colons here

                    int subs[VT100CSISUBPARAM_MAX];
                    int numberOfSubparameters = iTermParserGetAllCSISubparametersForParameter(token.csi, i, subs);
                    if (numberOfSubparameters > 0) {
                        // Preferred syntax using colons to delimit subparameters
                        if (numberOfSubparameters >= 2 && subs[0] == 5) {
                            // CSI 38:5:P m
                            graphicRendition_.fgColorCode = subs[1];
                            graphicRendition_.fgGreen = 0;
                            graphicRendition_.fgBlue = 0;
                            graphicRendition_.fgColorMode = ColorModeNormal;
                        } else if (numberOfSubparameters >= 4 && subs[0] == 2) {
                            // 24-bit color
                            if (numberOfSubparameters >= 5) {
                                // Spec-compliant. Likely rarely used in 2017.
                                // CSI 38:2:colorspace:R:G:B m
                                // TODO: Respect the color space argument. See ITU-T Rec. T.414,
                                // but good luck actually finding the colour space IDs.
                                graphicRendition_.fgColorCode = subs[2];
                                graphicRendition_.fgGreen = subs[3];
                                graphicRendition_.fgBlue = subs[4];
                                graphicRendition_.fgColorMode = ColorMode24bit;
                            } else {
                                // Misinterpretation compliant.
                                // CSI 38:2:R:G:B m  <- misinterpretation compliant
                                graphicRendition_.fgColorCode = subs[1];
                                graphicRendition_.fgGreen = subs[2];
                                graphicRendition_.fgBlue = subs[3];
                                graphicRendition_.fgColorMode = ColorMode24bit;
                            }
                        }
                    } else if (token.csi->count - i >= 3 && token.csi->p[i + 1] == 5) {
                        // For 256-color mode (indexed) use this for the foreground:
                        // CSI 38;5;N m
                        // where N is a value between 0 and 255. See the colors described in screen_char_t
                        // in the comments for fgColorCode.
                        graphicRendition_.fgColorCode = token.csi->p[i + 2];
                        graphicRendition_.fgGreen = 0;
                        graphicRendition_.fgBlue = 0;
                        graphicRendition_.fgColorMode = ColorModeNormal;
                        i += 2;
                    } else if (token.csi->count - i >= 5 && token.csi->p[i + 1] == 2) {
                        // CSI 38;2;R;G;B m
                        // Hack for xterm compatibility
                        // 24-bit color support
                        graphicRendition_.fgColorCode = token.csi->p[i + 2];
                        graphicRendition_.fgGreen = token.csi->p[i + 3];
                        graphicRendition_.fgBlue = token.csi->p[i + 4];
                        graphicRendition_.fgColorMode = ColorMode24bit;
                        i += 4;
                    }
                    break;
                }
                case VT100CHARATTR_BG_256: {
                    int subs[VT100CSISUBPARAM_MAX];
                    int numberOfSubparameters = iTermParserGetAllCSISubparametersForParameter(token.csi, i, subs);
                    if (numberOfSubparameters > 0) {
                        // Preferred syntax using colons to delimit subparameters
                        if (numberOfSubparameters >= 2 && subs[0] == 5) {
                            // CSI 48:5:P m
                            graphicRendition_.bgColorCode = subs[1];
                            graphicRendition_.bgGreen = 0;
                            graphicRendition_.bgBlue = 0;
                            graphicRendition_.bgColorMode = ColorModeNormal;
                        } else if (numberOfSubparameters >= 4 && subs[0] == 2) {
                            // 24-bit color
                            if (numberOfSubparameters >= 5) {
                                // Spec-compliant. Likely rarely used in 2020.
                                // CSI 48:2:colorspace:R:G:B m
                                // TODO: Respect the color space argument. See ITU-T Rec. T.414,
                                // but good luck actually finding the colour space IDs.
                                graphicRendition_.bgColorCode = subs[2];
                                graphicRendition_.bgGreen = subs[3];
                                graphicRendition_.bgBlue = subs[4];
                                graphicRendition_.bgColorMode = ColorMode24bit;
                            } else {
                                // Misinterpretation compliant.
                                // CSI 48:2:R:G:B m  <- misinterpretation compliant
                                graphicRendition_.bgColorCode = subs[1];
                                graphicRendition_.bgGreen = subs[2];
                                graphicRendition_.bgBlue = subs[3];
                                graphicRendition_.bgColorMode = ColorMode24bit;
                            }
                        }
                    } else if (token.csi->count - i >= 3 && token.csi->p[i + 1] == 5) {
                        // CSI 48;5;P m
                        graphicRendition_.bgColorCode = token.csi->p[i + 2];
                        graphicRendition_.bgGreen = 0;
                        graphicRendition_.bgBlue = 0;
                        graphicRendition_.bgColorMode = ColorModeNormal;
                        i += 2;
                    } else if (token.csi->count - i >= 5 && token.csi->p[i + 1] == 2) {
                        // CSI 48;2;R;G;B m
                        // Hack for xterm compatibility
                        // 24-bit color
                        graphicRendition_.bgColorCode = token.csi->p[i + 2];
                        graphicRendition_.bgGreen = token.csi->p[i + 3];
                        graphicRendition_.bgBlue = token.csi->p[i + 4];
                        graphicRendition_.bgColorMode = ColorMode24bit;
                        i += 4;
                    }
                    break;
                }
                default:
                    // 8 color support
                    if (n >= VT100CHARATTR_FG_BLACK &&
                        n <= VT100CHARATTR_FG_WHITE) {
                        graphicRendition_.fgColorCode = n - VT100CHARATTR_FG_BASE - COLORCODE_BLACK;
                        graphicRendition_.fgGreen = 0;
                        graphicRendition_.fgBlue = 0;
                        graphicRendition_.fgColorMode = ColorModeNormal;
                    } else if (n >= VT100CHARATTR_BG_BLACK &&
                               n <= VT100CHARATTR_BG_WHITE) {
                        graphicRendition_.bgColorCode = n - VT100CHARATTR_BG_BASE - COLORCODE_BLACK;
                        graphicRendition_.bgGreen = 0;
                        graphicRendition_.bgBlue = 0;
                        graphicRendition_.bgColorMode = ColorModeNormal;
                    }
                    // 16 color support
                    if (n >= VT100CHARATTR_FG_HI_BLACK &&
                        n <= VT100CHARATTR_FG_HI_WHITE) {
                        graphicRendition_.fgColorCode = n - VT100CHARATTR_FG_HI_BASE - COLORCODE_BLACK + 8;
                        graphicRendition_.fgGreen = 0;
                        graphicRendition_.fgBlue = 0;
                        graphicRendition_.fgColorMode = ColorModeNormal;
                    } else if (n >= VT100CHARATTR_BG_HI_BLACK &&
                               n <= VT100CHARATTR_BG_HI_WHITE) {
                        graphicRendition_.bgColorCode = n - VT100CHARATTR_BG_HI_BASE - COLORCODE_BLACK + 8;
                        graphicRendition_.bgGreen = 0;
                        graphicRendition_.bgBlue = 0;
                        graphicRendition_.bgColorMode = ColorModeNormal;
                    }
            }
        }
    }
}

- (NSColor *)colorForXtermCCSetPaletteString:(NSString *)argument colorNumberPtr:(int *)numberPtr {
    if ([argument length] == 7) {
        int n, r, g, b;
        int count = 0;
        count += sscanf([[argument substringWithRange:NSMakeRange(0, 1)] UTF8String], "%x", &n);
        if (count == 0) {
            unichar c = [argument characterAtIndex:0];
            n = c - 'a' + 10;
            // fg = 16 ('g')
            // bg = 17
            // bold = 18
            // selection = 19
            // selected text = 20
            // cursor = 21
            // cursor text = 22
            if (n >= 16 && n <= 22) {
                ++count;
            }
        }
        count += sscanf([[argument substringWithRange:NSMakeRange(1, 2)] UTF8String], "%x", &r);
        count += sscanf([[argument substringWithRange:NSMakeRange(3, 2)] UTF8String], "%x", &g);
        count += sscanf([[argument substringWithRange:NSMakeRange(5, 2)] UTF8String], "%x", &b);
        if (count == 4 &&
            n >= 0 &&
            n <= 22 &&
            r >= 0 &&
            r <= 255 &&
            g >= 0 &&
            g <= 255 &&
            b >= 0 &&
            b <= 255) {
            NSColor* srgb = [NSColor colorWithSRGBRed:((double)r)/255.0
                                                green:((double)g)/255.0
                                                 blue:((double)b)/255.0
                                                alpha:1];
            NSColor *theColor = [srgb colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
            *numberPtr = n;
            return theColor;
        }
    }
    return nil;
}

- (void)setMouseMode:(MouseMode)mode {
    if (_mouseMode != MOUSE_REPORTING_NONE) {
        _previousMouseMode = self.mouseMode;
    }
    _mouseMode = mode;
    [delegate_ terminalMouseModeDidChangeTo:_mouseMode];
}

- (void)handleDeviceStatusReportWithToken:(VT100Token *)token withQuestion:(BOOL)withQuestion {
    if ([delegate_ terminalShouldSendReport]) {
        switch (token.csi->p[0]) {
            case 3: // response from VT100 -- Malfunction -- retry
                break;

            case 5: // Command from host -- Please report status
                [delegate_ terminalSendReport:[self.output reportStatus]];
                break;

            case 6: // Command from host -- Please report active position
                if (self.originMode) {
                    // This is compatible with Terminal but not old xterm :(. it always did what
                    // we do in the else clause. This behavior of xterm is fixed by Patch #297.
                    [delegate_ terminalSendReport:[self.output reportActivePositionWithX:[delegate_ terminalRelativeCursorX]
                                                                                Y:[delegate_ terminalRelativeCursorY]
                                                                     withQuestion:withQuestion]];
                } else {
                    [delegate_ terminalSendReport:[self.output reportActivePositionWithX:[delegate_ terminalCursorX]
                                                                                Y:[delegate_ terminalCursorY]
                                                                     withQuestion:withQuestion]];
                }
                break;

            case 1337:  // iTerm2 extension
                [delegate_ terminalSendReport:[self.output reportiTerm2Version]];
                break;

            case 0: // Response from VT100 -- Ready, No malfunctions detected
            default:
                break;
        }
    }
}

- (VT100GridRect)rectangleInToken:(VT100Token *)token
                  startingAtIndex:(int)index
                 defaultRectangle:(VT100GridRect)defaultRectangle {
    CSIParam *csi = token.csi;
    VT100GridCoord defaultMax = VT100GridRectMax(defaultRectangle);

    // First, construct a coord range from the passed-in parameters. They may be -1 for default
    // values.
    int top = csi->p[index];
    int left = csi->p[index + 1];
    int bottom = csi->p[index + 2];
    int right = csi->p[index + 3];
    VT100GridCoordRange coordRange = VT100GridCoordRangeMake(left, top, right, bottom);

    // Replace default values with the passed-in defaults.
    if (coordRange.start.x < 0) {
        coordRange.start.x = defaultRectangle.origin.x + 1;
    }
    if (coordRange.start.y < 0) {
        coordRange.start.y = defaultRectangle.origin.y + 1;
    }
    if (coordRange.end.x < 0) {
        coordRange.end.x = defaultMax.x + 1;
    }
    if (coordRange.end.y < 0) {
        coordRange.end.y = defaultMax.y + 1;
    }

    if (self.originMode) {
        VT100GridRect scrollRegion = [delegate_ terminalScrollRegion];
        coordRange.start.x += scrollRegion.origin.x;
        coordRange.start.y += scrollRegion.origin.y;
        coordRange.end.x += scrollRegion.origin.x;
        coordRange.end.y += scrollRegion.origin.y;
    }

    // Convert the coordRange to a 0-based rect (all coords are 1-based so far) and return it.
    return VT100GridRectMake(MAX(0, coordRange.start.x - 1),
                             MAX(0, coordRange.start.y - 1),
                             coordRange.end.x - coordRange.start.x + 1,
                             coordRange.end.y - coordRange.start.y + 1);
}

- (BOOL)rectangleIsValid:(VT100GridRect)rect {
    if (self.originMode) {
        VT100GridRect scrollRegion = [delegate_ terminalScrollRegion];
        if (rect.origin.y < scrollRegion.origin.y ||
            rect.origin.x < scrollRegion.origin.x ||
            VT100GridRectMax(rect).y > VT100GridRectMax(scrollRegion).y ||
            VT100GridRectMax(rect).x > VT100GridRectMax(scrollRegion).x) {
            return NO;
        }
    }
    return (rect.size.width >= 0 &&
            rect.size.height >= 0);
}

- (void)sendChecksumReportWithId:(int)identifier
                       rectangle:(VT100GridRect)rect {
    if (![delegate_ terminalShouldSendReport]) {
        return;
    }
    if (identifier < 0) {
        return;
    }
    if (![self rectangleIsValid:rect]) {
        [delegate_ terminalSendReport:[self.output reportChecksum:0 withIdentifier:identifier]];
        return;
    }
    // TODO: Respect origin mode
    int checksum = [delegate_ terminalChecksumInRectangle:rect];
    // DCS Pid ! ~ D..D ST
    [delegate_ terminalSendReport:[self.output reportChecksum:checksum withIdentifier:identifier]];
}

- (void)sendSGRReportWithRectangle:(VT100GridRect)rect {
    if (![delegate_ terminalShouldSendReport]) {
        return;
    }
    if (![self rectangleIsValid:rect]) {
        [delegate_ terminalSendReport:[self.output reportSGRCodes:@[]]];
        return;
    }
    // TODO: Respect origin mode
    NSArray<NSString *> *codes = [delegate_ terminalSGRCodesInRectangle:rect];
    [delegate_ terminalSendReport:[self.output reportSGRCodes:codes]];
}

- (NSString *)decodedBase64PasteCommand:(NSString *)commandString {
    //
    // - write access
    //   ESC ] 5 2 ; Pc ; <base64 encoded string> ST
    //
    // - read access
    //   ESC ] 5 2 ; Pc ; ? ST
    //
    // Pc consists from:
    //   'p', 's', 'c', '0', '1', '2', '3', '4', '5', '6', '7'
    //
    // Note: Pc is ignored now.
    //
    const char *buffer = [commandString UTF8String];

    // ignore first parameter now
    while (strchr("psc01234567", *buffer)) {
        ++buffer;
    }
    if (*buffer != ';') {
        return nil; // fail to parse
    }
    ++buffer;
    if (*buffer == '?') { // PASTE64(OSC 52) read access
        // Now read access is not implemented due to security issues.
        return nil;
    }

    // decode base64 string.
    int destLength = apr_base64_decode_len(buffer);
    if (destLength < 1) {
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:destLength];
    char *decodedBuffer = [data mutableBytes];
    int resultLength = apr_base64_decode(decodedBuffer, buffer);
    if (resultLength < 0) {
        return nil;
    }

    // sanitize buffer
    const char *inputIterator = decodedBuffer;
    char *outputIterator = decodedBuffer;
    int outputLength = 0;
    for (int i = 0; i < resultLength + 1; ++i) {
        char c = *inputIterator;
        if (c == 0x00) {
            *outputIterator = 0; // terminate string with NULL
            break;
        }
        if (c > 0 && c < 0x20) { // if c is control character
            // check if c is TAB/LF/CR
            if (c != 0x9 && c != 0xa && c != 0xd) {
                // skip it
                ++inputIterator;
                continue;
            }
        }
        *outputIterator = c;
        ++inputIterator;
        ++outputIterator;
        ++outputLength;
    }
    [data setLength:outputLength];

    NSString *resultString = [[[NSString alloc] initWithData:data
                                                    encoding:[self encoding]] autorelease];
    return resultString;
}

// The main and alternate screens have different saved cursors. This returns the current one. In
// tmux mode, only one is used to more closely approximate tmux's behavior.
- (VT100SavedCursor *)savedCursor {
    if (_tmuxMode) {
        return &mainSavedCursor_;
    }
    VT100SavedCursor *savedCursor;
    if ([delegate_ terminalIsShowingAltBuffer]) {
        savedCursor = &altSavedCursor_;
    } else {
        savedCursor = &mainSavedCursor_;
    }
    return savedCursor;
}

- (void)saveCursor {
    VT100SavedCursor *savedCursor = [self savedCursor];

    savedCursor->position = VT100GridCoordMake([delegate_ terminalCursorX] - 1,
                                               [delegate_ terminalCursorY] - 1);
    savedCursor->charset = _charset;

    for (int i = 0; i < NUM_CHARSETS; i++) {
        savedCursor->lineDrawing[i] = [delegate_ terminalLineDrawingFlagForCharset:i];
    }
    savedCursor->graphicRendition = graphicRendition_;
    savedCursor->origin = self.originMode;
    savedCursor->wraparound = self.wraparoundMode;
    savedCursor->unicodeVersion = [delegate_ terminalUnicodeVersion];
}

- (void)setReportFocus:(BOOL)reportFocus {
    [self.delegate terminalReportFocusWillChangeTo:reportFocus];
    _reportFocus = reportFocus;
}

- (void)setBracketedPasteMode:(BOOL)bracketedPasteMode {
    [self setBracketedPasteMode:bracketedPasteMode withSideEffects:NO];
}

- (void)setBracketedPasteMode:(BOOL)bracketedPasteMode withSideEffects:(BOOL)sideEffects {
    if (sideEffects) {
        [delegate_ terminalPasteBracketingWillChangeTo:bracketedPasteMode];
    }
    _bracketedPasteMode = bracketedPasteMode;
}

- (void)resetSavedCursorPositions {
    mainSavedCursor_.position = VT100GridCoordMake(0, 0);
    altSavedCursor_.position = VT100GridCoordMake(0, 0);
}

- (void)clampSavedCursorToScreenSize:(VT100GridSize)newSize {
    mainSavedCursor_.position = VT100GridCoordMake(MIN(newSize.width - 1, mainSavedCursor_.position.x),
                                                   MIN(newSize.height - 1, mainSavedCursor_.position.y));
    altSavedCursor_.position = VT100GridCoordMake(MIN(newSize.width - 1, altSavedCursor_.position.x),
                                                  MIN(newSize.height - 1, altSavedCursor_.position.y));
}

- (void)setSavedCursorPosition:(VT100GridCoord)position {
    VT100SavedCursor *savedCursor = [self savedCursor];
    savedCursor->position = position;
}

- (void)restoreCursor {
    VT100SavedCursor *savedCursor = [self savedCursor];
    [delegate_ terminalSetCursorX:savedCursor->position.x + 1];
    [delegate_ terminalSetCursorY:savedCursor->position.y + 1];
    _charset = savedCursor->charset;
    for (int i = 0; i < NUM_CHARSETS; i++) {
        [delegate_ terminalSetCharset:i toLineDrawingMode:savedCursor->lineDrawing[i]];
    }

    graphicRendition_ = savedCursor->graphicRendition;

    self.originMode = savedCursor->origin;
    self.wraparoundMode = savedCursor->wraparound;
    [delegate_ terminalSetUnicodeVersion:savedCursor->unicodeVersion];
}

// These steps are derived from xterm's source.
- (void)softReset {
    // The steps here are derived from xterm's implementation. The order is different but not in
    // a significant way.
    int x = [delegate_ terminalCursorX];
    int y = [delegate_ terminalCursorY];

    // Show cursor
    [delegate_ terminalSetCursorVisible:YES];

    // Reset cursor shape to default
    [delegate_ terminalSetCursorType:CURSOR_DEFAULT];

    // Remove tb and lr margins
    [delegate_ terminalSetScrollRegionTop:0
                                   bottom:[delegate_ terminalHeight] - 1];
    [delegate_ terminalSetLeftMargin:0 rightMargin:[delegate_ terminalWidth] - 1];


    // Turn off origin mode
    self.originMode = NO;

    // Reset colors
    graphicRendition_.fgColorCode = 0;
    graphicRendition_.fgGreen = 0;
    graphicRendition_.fgBlue = 0;
    graphicRendition_.fgColorMode = 0;

    graphicRendition_.bgColorCode = 0;
    graphicRendition_.bgGreen = 0;
    graphicRendition_.bgBlue = 0;
    graphicRendition_.bgColorMode = 0;

    // Reset character-sets to initial state
    _charset = 0;
    for (int i = 0; i < NUM_CHARSETS; i++) {
        [delegate_ terminalSetCharset:i toLineDrawingMode:NO];
    }

    // (Not supported: Reset DECSCA)
    // Reset DECCKM
    self.cursorMode = NO;

    // (Not supported: Reset KAM)

    // Reset DECKPAM
    self.keypadMode = NO;

    self.reportKeyUp = NO;
    self.metaSendsEscape = NO;

    // Set WRAPROUND to initial value
    self.wraparoundMode = YES;

    // Set REVERSEWRAP to initial value
    self.reverseWraparoundMode = NO;

    // Reset INSERT
    self.insertMode = NO;

    // Reset SRM
    self.sendReceiveMode = NO;

    // Reset INVERSE
    graphicRendition_.reversed = NO;

    // Reset BOLD
    graphicRendition_.bold = NO;

    // Reset BLINK
    graphicRendition_.blink = NO;

    // Reset UNDERLINE & STRIKETHROUGH
    graphicRendition_.underline = NO;
    graphicRendition_.strikethrough = NO;
    graphicRendition_.underlineStyle = VT100UnderlineStyleSingle;

    self.url = nil;
    self.urlParams = nil;
    _currentURLCode = 0;

    // (Not supported: Reset INVISIBLE)

    // Save screen flags
    // Save fg, bg colors
    // Save charset flags
    // Save current charset
    [self saveCursor];

    // Reset saved cursor position to 1,1.
    VT100SavedCursor *savedCursor = [self savedCursor];
    savedCursor->position = VT100GridCoordMake(0, 0);

    [delegate_ terminalSetCursorX:x];
    [delegate_ terminalSetCursorY:y];
}

- (VT100GridCoord)savedCursorPosition {
    VT100SavedCursor *savedCursor = [self savedCursor];
    return savedCursor->position;
}

- (void)executeToken:(VT100Token *)token {
    // Handle tmux stuff, which completely bypasses all other normal execution steps.
    if (token->type == DCS_TMUX_HOOK) {
        [delegate_ terminalStartTmuxModeWithDCSIdentifier:token.string];
        return;
    } else if (token->type == TMUX_EXIT || token->type == TMUX_LINE) {
        [delegate_ terminalHandleTmuxInput:token];
        return;
    }

    if ([iTermAdvancedSettingsModel translateScreenToXterm] && [self.termType containsString:@"screen"]) {
        [token translateFromScreenTerminal];
    }

    // Handle file downloads, which come as a series of MULTITOKEN_BODY tokens.
    if (receivingFile_) {
        if (token->type == XTERMCC_MULTITOKEN_BODY) {
            [delegate_ terminalDidReceiveBase64FileData:token.string ?: @""];
            return;
        } else if (token->type == VT100_ASCIISTRING) {
            [delegate_ terminalDidReceiveBase64FileData:[token stringForAsciiData]];
            return;
        } else if (token->type == XTERMCC_MULTITOKEN_END) {
            [delegate_ terminalDidFinishReceivingFile];
            receivingFile_ = NO;
            return;
        } else {
            DLog(@"Unexpected field receipt end");
            [delegate_ terminalFileReceiptEndedUnexpectedly];
            receivingFile_ = NO;
        }
    } else if (_copyingToPasteboard) {
        if (token->type == XTERMCC_MULTITOKEN_BODY) {
            [delegate_ terminalDidReceiveBase64PasteboardString:token.string ?: @""];
            return;
        } else if (token->type == VT100_ASCIISTRING) {
            [delegate_ terminalDidReceiveBase64PasteboardString:[token stringForAsciiData]];
            return;
        } else if (token->type == XTERMCC_MULTITOKEN_END) {
            [delegate_ terminalDidFinishReceivingPasteboard];
            _copyingToPasteboard = NO;
            return;
        } else {
            [delegate_ terminalPasteboardReceiptEndedUnexpectedly];
            _copyingToPasteboard = NO;
        }
    }
    if (token->savingData &&
        token->type != VT100_SKIP &&
        [delegate_ terminalIsAppendingToPasteboard]) {  // This is the old code that echoes to the screen. Its use is discouraged.
        // We are probably copying text to the clipboard until esc]1337;EndCopy^G is received.
        if (token->type != XTERMCC_SET_KVP ||
            ![token.string hasPrefix:@"CopyToClipboard"]) {
            // Append text to clipboard except for initial command that turns on copying to
            // the clipboard.

            [delegate_ terminalAppendDataToPasteboard:token.savedData];
        }
    }

    // Disambiguate
    switch (token->type) {
        case VT100CSI_DECSLRM_OR_ANSICSI_SCP:
            if ([delegate_ terminalUseColumnScrollRegion]) {
                token->type = VT100CSI_DECSLRM;
                iTermParserSetCSIParameterIfDefault(token.csi, 0, 1);
                iTermParserSetCSIParameterIfDefault(token.csi, 1, 1);
            } else {
                token->type = ANSICSI_SCP;
                iTermParserSetCSIParameterIfDefault(token.csi, 0, 0);
            }
            break;

        default:
            break;
    }

    // Farm out work to the delegate.
    switch (token->type) {
        // our special code
        case VT100_STRING:
            [delegate_ terminalAppendString:token.string];
            break;
        case VT100_ASCIISTRING:
            [delegate_ terminalAppendAsciiData:token.asciiData];
            break;

        case VT100_UNKNOWNCHAR:
            break;
        case VT100_NOTSUPPORT:
            break;

        //  VT100 CC
        case VT100CC_ENQ:
            [delegate_ terminalSendReport:[_answerBackString dataUsingEncoding:self.encoding]];
            break;
        case VT100CC_BEL:
            [delegate_ terminalRingBell];
            break;
        case VT100CC_BS:
            [delegate_ terminalBackspace];
            break;
        case VT100CC_HT:
            [delegate_ terminalAppendTabAtCursor:!_softAlternateScreenMode];
            break;
        case VT100CC_LF:
        case VT100CC_VT:
        case VT100CC_FF:
            [delegate_ terminalLineFeed];
            break;
        case VT100CC_CR:
            [delegate_ terminalCarriageReturn];
            break;
        case VT100CC_SI:
            _charset = 0;
            break;
        case VT100CC_SO:
            _charset = 1;
            break;
        case VT100CC_DC1:
        case VT100CC_DC3:
            // Set XON/XOFF, but why would we want to support that?
            break;
        case VT100CC_CAN:
        case VT100CC_SUB:
        case VT100CC_DEL:
            break;

        // VT100 CSI
        case VT100CSI_CPR:
            break;
        case VT100CSI_CUB:
            [delegate_ terminalCursorLeft:token.csi->p[0] > 0 ? token.csi->p[0] : 1];
            break;
        case VT100CSI_CUD:
            [delegate_ terminalCursorDown:token.csi->p[0] > 0 ? token.csi->p[0] : 1
                         andToStartOfLine:NO];
            break;
        case VT100CSI_CUF:
            [delegate_ terminalCursorRight:token.csi->p[0] > 0 ? token.csi->p[0] : 1];
            break;
        case VT100CSI_CUP:
            [delegate_ terminalMoveCursorToX:token.csi->p[1] y:token.csi->p[0]];
            break;
        case VT100CSI_CHT:
            for (int i = 0; i < token.csi->p[0]; i++) {
                [delegate_ terminalAppendTabAtCursor:!_softAlternateScreenMode];
            }
            break;
        case VT100CSI_CUU:
            [delegate_ terminalCursorUp:token.csi->p[0] > 0 ? token.csi->p[0] : 1
                       andToStartOfLine:NO];
            break;
        case VT100CSI_CNL:
            [delegate_ terminalCursorDown:token.csi->p[0] > 0 ? token.csi->p[0] : 1
                         andToStartOfLine:YES];
            break;
        case VT100CSI_CPL:
            [delegate_ terminalCursorUp:token.csi->p[0] > 0 ? token.csi->p[0] : 1
                       andToStartOfLine:YES];
            break;
        case VT100CSI_DA:
            if ([delegate_ terminalShouldSendReport]) {
                [delegate_ terminalSendReport:[self.output reportDeviceAttribute]];
            }
            break;
        case VT100CSI_DA2:
            if ([delegate_ terminalShouldSendReport]) {
                [delegate_ terminalSendReport:[self.output reportSecondaryDeviceAttribute]];
            }
            break;
        case VT100CSI_XDA:
            if ([delegate_ terminalShouldSendReport]) {
                if (token.csi->p[0] == 0 || token.csi->p[0] == -1) {
                    [delegate_ terminalSendReport:[self.output reportExtendedDeviceAttribute]];
                }
            }
            break;
        case VT100CSI_DECALN:
            [delegate_ terminalShowTestPattern];
            break;
        case VT100CSI_DECDHL:
        case VT100CSI_DECDWL:
        case VT100CSI_DECID:
            break;
        case VT100CSI_DECKPNM:
            self.keypadMode = NO;
            break;
        case VT100CSI_DECKPAM:
            self.keypadMode = YES;
            break;

        case ANSICSI_RCP:
        case VT100CSI_DECRC:
            [self restoreCursor];
            break;

        case ANSICSI_SCP:
            // ANSI SC is just like DECSC, but it's only available when left-right mode is off.
            // There's code before the big switch statement that changes the token type for this
            // case, so if we get here it's definitely the same as DECSC.
            // Fall through.
        case VT100CSI_DECSC:
            [self saveCursor];
            break;

        case VT100CSI_DECSTBM: {
            int top;
            if (token.csi->count == 0 || token.csi->p[0] < 0) {
                top = 0;
            } else {
                top = MAX(1, token.csi->p[0]) - 1;
            }

            int bottom;
            if (token.csi->count < 2 || token.csi->p[1] <= 0) {
                bottom = delegate_.terminalHeight - 1;
            } else {
                bottom = MIN(delegate_.terminalHeight, token.csi->p[1]) - 1;
            }

            [delegate_ terminalSetScrollRegionTop:top
                                           bottom:bottom];
            // http://www.vt100.net/docs/vt510-rm/DECSTBM.html says:
            // “DECSTBM moves the cursor to column 1, line 1 of the page.”
            break;
        }
        case VT100CSI_DSR:
            [self handleDeviceStatusReportWithToken:token withQuestion:NO];
            break;
        case VT100CSI_DECRQCRA: {
            if ([delegate_ terminalIsTrusted]) {
                if (![delegate_ terminalCanUseDECRQCRA]) {
                    break;
                }
                VT100GridRect defaultRectangle = VT100GridRectMake(0,
                                                                   0,
                                                                   [delegate_ terminalWidth],
                                                                   [delegate_ terminalHeight]);
                // xterm incorrectly uses the second parameter for the Pid. Since I use this mostly to
                // test xterm compatibility, it's handy to be bugwards-compatible.
                [self sendChecksumReportWithId:token.csi->p[1]
                                     rectangle:[self rectangleInToken:token
                                                      startingAtIndex:2
                                                     defaultRectangle:defaultRectangle]];
            }
            break;
        }
        case VT100CSI_DECDSR:
            [self handleDeviceStatusReportWithToken:token withQuestion:YES];
            break;
        case VT100CSI_ED:
            switch (token.csi->p[0]) {
                case 1:
                    [delegate_ terminalEraseInDisplayBeforeCursor:YES afterCursor:NO];
                    break;

                case 2:
                    [delegate_ terminalEraseInDisplayBeforeCursor:YES afterCursor:YES];
                    break;

                case 3:
                    [delegate_ terminalClearScrollbackBuffer];
                    break;

                case 0:
                default:
                    [delegate_ terminalEraseInDisplayBeforeCursor:NO afterCursor:YES];
                    break;
            }
            break;
        case VT100CSI_EL:
            switch (token.csi->p[0]) {
                case 1:
                    [delegate_ terminalEraseLineBeforeCursor:YES afterCursor:NO];
                    break;
                case 2:
                    [delegate_ terminalEraseLineBeforeCursor:YES afterCursor:YES];
                    break;
                case 0:
                    [delegate_ terminalEraseLineBeforeCursor:NO afterCursor:YES];
                    break;
            }
            break;
        case VT100CSI_HTS:
            [delegate_ terminalSetTabStopAtCursor];
            break;
        case VT100CSI_HVP:
            [delegate_ terminalMoveCursorToX:token.csi->p[1] y:token.csi->p[0]];
            break;
        case VT100CSI_NEL:
            // We do the linefeed first because it's a no-op if the cursor is outside the left-
            // right margin. Carriage return will move it to the left margin.
            [delegate_ terminalLineFeed];
            [delegate_ terminalCarriageReturn];
            break;
        case VT100CSI_IND:
            [delegate_ terminalLineFeed];
            break;
        case VT100CSI_RI:
            [delegate_ terminalReverseIndex];
            break;
        case VT100CSI_RIS:
            // As far as I can tell, this is not part of the standard and should not be
            // supported.  -- georgen 7/31/11
            break;

        case ANSI_RIS:
            [self resetByUserRequest:NO];
            break;
        case VT100CSI_SM:
        case VT100CSI_RM: {
            int mode = (token->type == VT100CSI_SM);

            for (int i = 0; i < token.csi->count; i++) {
                switch (token.csi->p[i]) {
                    case 4:
                        self.insertMode = mode;
                        break;
                    case 12:
                        self.sendReceiveMode = !mode;
                        break;
                }
            }
            break;
        }
        case VT100CSI_XTREPORTSGR: {
            if ([delegate_ terminalIsTrusted]) {
                VT100GridRect defaultRectangle = VT100GridRectMake(0,
                                                                   0,
                                                                   [delegate_ terminalWidth],
                                                                   [delegate_ terminalHeight]);
                [self sendSGRReportWithRectangle:[self rectangleInToken:token
                                                        startingAtIndex:0
                                                       defaultRectangle:defaultRectangle]];
            }
            break;
        }

        case VT100CSI_DECSTR:
            [self softReset];
            break;
        case VT100CSI_DECSCUSR:
            switch (token.csi->p[0]) {
                case 0:
                    [delegate_ terminalResetCursorTypeAndBlink];
                    break;
                case 1:
                    [delegate_ terminalSetCursorBlinking:YES];
                    [delegate_ terminalSetCursorType:CURSOR_BOX];
                    break;
                case 2:
                    [delegate_ terminalSetCursorBlinking:NO];
                    [delegate_ terminalSetCursorType:CURSOR_BOX];
                    break;
                case 3:
                    [delegate_ terminalSetCursorBlinking:YES];
                    [delegate_ terminalSetCursorType:CURSOR_UNDERLINE];
                    break;
                case 4:
                    [delegate_ terminalSetCursorBlinking:NO];
                    [delegate_ terminalSetCursorType:CURSOR_UNDERLINE];
                    break;
                case 5:
                    [delegate_ terminalSetCursorBlinking:YES];
                    [delegate_ terminalSetCursorType:CURSOR_VERTICAL];
                    break;
                case 6:
                    [delegate_ terminalSetCursorBlinking:NO];
                    [delegate_ terminalSetCursorType:CURSOR_VERTICAL];
                    break;
            }
            break;

        case VT100CSI_DECSLRM: {
            int scrollLeft = token.csi->p[0] - 1;
            int scrollRight = token.csi->p[1] - 1;
            int width = [delegate_ terminalWidth];
            if (scrollLeft < 0) {
                scrollLeft = 0;
            }
            if (scrollRight == 0) {
                scrollRight = width - 1;
            }
            // check wrong parameter
            if (scrollRight - scrollLeft < 1) {
                scrollLeft = 0;
                scrollRight = width - 1;
            }
            if (scrollRight > width - 1) {
                scrollRight = width - 1;
            }
            [delegate_ terminalSetLeftMargin:scrollLeft rightMargin:scrollRight];
            break;
        }

            /* My interpretation of this:
             * http://www.cl.cam.ac.uk/~mgk25/unicode.html#term
             * is that UTF-8 terminals should ignore SCS because
             * it's either a no-op (in the case of iso-8859-1) or
             * insane. Also, mosh made fun of Terminal and I don't
             * want to be made fun of:
             * "Only Mosh will never get stuck in hieroglyphs when a nasty
             * program writes to the terminal. (See Markus Kuhn's discussion of
             * the relationship between ISO 2022 and UTF-8.)"
             * http://mosh.mit.edu/#techinfo
             *
             * I'm going to throw this out there (4/15/2012) and see if this breaks
             * anything for anyone.
             *
             * UPDATE: In bug 1997, we see that it breaks line-drawing chars, which
             * are in SCS0. Indeed, mosh fails to draw these as well.
             *
             * UPDATE: In bug 2358, we see that SCS1 is also legitimately used in
             * UTF-8.
             *
             * Here's my take on the way things work. There are four charsets: G0
             * (default), G1, G2, and G3. They are switched between with codes like SI
             * (^O), SO (^N), LS2 (ESC n), and LS3 (ESC o). You can get the current
             * character set from [terminal_ charset], and that gives you a number from
             * 0 to 3 inclusive. It is an index into Screen's charsetUsesLineDrawingMode_ array.
             * In iTerm2, it is an array of booleans where 0 means normal behavior and 1 means
             * line-drawing. There should be a bunch of other values too (like
             * locale-specific char sets). This is pretty far away from the spec,
             * but it works well enough for common behavior, and it seems the spec
             * doesn't work well with common behavior (esp line drawing).
             */
        case VT100CSI_SCS0:
            [delegate_ terminalSetCharset:0 toLineDrawingMode:(token->code=='0')];
            break;
        case VT100CSI_SCS1:
            [delegate_ terminalSetCharset:1 toLineDrawingMode:(token->code=='0')];
            break;
        case VT100CSI_SCS2:
            [delegate_ terminalSetCharset:2 toLineDrawingMode:(token->code=='0')];
            break;
        case VT100CSI_SCS3:
            [delegate_ terminalSetCharset:3 toLineDrawingMode:(token->code=='0')];
            break;

        // The parser sets its own encoding property when these codes are parsed because it must
        // change synchronously, since it also does decoding in its own thread (possibly long before
        // this happens in the main thread).
        case ISO2022_SELECT_UTF_8:
            _encoding = NSUTF8StringEncoding;
            break;
        case ISO2022_SELECT_LATIN_1:
            _encoding = NSISOLatin1StringEncoding;
            break;

        case VT100CSI_SGR:
            [self executeSGR:token];
            break;

        case VT100CSI_TBC:
            switch (token.csi->p[0]) {
                case 3:
                    [delegate_ terminalRemoveTabStops];
                    break;

                case 0:
                    [delegate_ terminalRemoveTabStopAtCursor];
            }
            break;

        case VT100CSI_DECSET:
        case VT100CSI_DECRST:
            [self executeDecSetReset:token];
            break;

        case VT100CSI_REP:
            [delegate_ terminalRepeatPreviousCharacter:token.csi->p[0]];
            break;

        case VT100CSI_DECRQM_ANSI:
            [self executeANSIRequestMode:token.csi->p[0]];
            break;

        case VT100CSI_PUSH_KEY_REPORTING_MODE:
            [_keyReportingModeStack addObject:@(token.csi->p[0])];
            [self.delegate terminalKeyReportingFlagsDidChange];
            break;

        case VT100CSI_POP_KEY_REPORTING_MODE:
            if (_keyReportingModeStack.count == 0) {
                break;
            }
            [_keyReportingModeStack removeLastObject];
            [self.delegate terminalKeyReportingFlagsDidChange];
            break;

        case VT100CSI_QUERY_KEY_REPORTING_MODE:
            if ([delegate_ terminalShouldSendReport]) {
                [delegate_ terminalSendReport:[_output reportKeyReportingMode:_keyReportingModeStack.lastObject.intValue]];
            }
            break;

        case VT100CSI_DECRQM_DEC:
            [self executeDECRequestMode:token.csi->p[0]];
            break;

            // ANSI CSI
        case ANSICSI_CBT:
            [delegate_ terminalBackTab:token.csi->p[0]];
            break;
        case ANSICSI_CHA:
            [delegate_ terminalSetCursorX:token.csi->p[0]];
            break;
        case ANSICSI_VPA:
            [delegate_ terminalSetCursorY:token.csi->p[0]];
            break;
        case ANSICSI_VPR:
            [delegate_ terminalCursorDown:token.csi->p[0] > 0 ? token.csi->p[0] : 1
                         andToStartOfLine:NO];
            break;
        case ANSICSI_ECH:
            [delegate_ terminalEraseCharactersAfterCursor:token.csi->p[0]];
            break;

        case STRICT_ANSI_MODE:
            self.strictAnsiMode = !self.strictAnsiMode;
            break;

        case ANSICSI_PRINT:
            switch (token.csi->p[0]) {
                case 4:
                    [delegate_ terminalPrintBuffer];
                    break;
                case 5:
                    [delegate_ terminalBeginRedirectingToPrintBuffer];
                    break;
                default:
                    [delegate_ terminalPrintScreen];
            }
            break;

            // XTERM extensions
        case XTERMCC_WIN_TITLE:
            [delegate_ terminalSetWindowTitle:[self sanitizedTitle:[token.string stringByReplacingControlCharactersWithCaretLetter]]];
            break;
        case XTERMCC_WINICON_TITLE:
            [delegate_ terminalSetWindowTitle:[self sanitizedTitle:[token.string stringByReplacingControlCharactersWithCaretLetter]]];
            [delegate_ terminalSetIconTitle:[self sanitizedTitle:[token.string stringByReplacingControlCharactersWithCaretLetter]]];
            break;
        case XTERMCC_PASTE64: {
            if (token.string) {
                NSString *decoded = [self decodedBase64PasteCommand:token.string];
                if (decoded) {
                    [delegate_ terminalPasteString:decoded];
                }
            }
            break;
        }
        case XTERMCC_FINAL_TERM:
            [self executeFinalTermToken:token];
            break;
        case XTERMCC_ICON_TITLE:
            [delegate_ terminalSetIconTitle:[token.string stringByReplacingControlCharactersWithCaretLetter]];
            break;
        case VT100CSI_ICH:
            [delegate_ terminalInsertEmptyCharsAtCursor:token.csi->p[0]];
            break;
        case XTERMCC_INSLN:
            [delegate_ terminalInsertBlankLinesAfterCursor:token.csi->p[0]];
            break;
        case XTERMCC_DELCH:
            [delegate_ terminalDeleteCharactersAtCursor:token.csi->p[0]];
            break;
        case XTERMCC_DELLN:
            [delegate_ terminalDeleteLinesAtCursor:token.csi->p[0]];
            break;
        case XTERMCC_WINDOWSIZE:
            [delegate_ terminalSetRows:MIN(token.csi->p[1], kMaxScreenRows)
                            andColumns:MIN(token.csi->p[2], kMaxScreenColumns)];
            break;
        case XTERMCC_WINDOWSIZE_PIXEL:
            [delegate_ terminalSetPixelWidth:token.csi->p[2]
                                      height:token.csi->p[1]];

            break;
        case XTERMCC_WINDOWPOS:
            [delegate_ terminalMoveWindowTopLeftPointTo:NSMakePoint(token.csi->p[1], token.csi->p[2])];
            break;
        case XTERMCC_ICONIFY:
            [delegate_ terminalMiniaturize:YES];
            break;
        case XTERMCC_DEICONIFY:
            [delegate_ terminalMiniaturize:NO];
            break;
        case XTERMCC_RAISE:
            [delegate_ terminalRaise:YES];
            break;
        case XTERMCC_LOWER:
            [delegate_ terminalRaise:NO];
            break;
        case XTERMCC_SU:
            [delegate_ terminalScrollUp:token.csi->p[0]];
            break;
        case XTERMCC_SD:
            if (token.csi->count == 1) {
                [delegate_ terminalScrollDown:token.csi->p[0]];
            }
            break;
        case XTERMCC_REPORT_WIN_STATE: {
            NSString *s = [NSString stringWithFormat:@"\033[%dt",
                           ([delegate_ terminalWindowIsMiniaturized] ? 2 : 1)];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case XTERMCC_REPORT_WIN_POS: {
            NSPoint topLeft = [delegate_ terminalWindowTopLeftPixelCoordinate];
            NSString *s = [NSString stringWithFormat:@"\033[3;%d;%dt",
                           (int)topLeft.x, (int)topLeft.y];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case XTERMCC_REPORT_WIN_PIX_SIZE: {
            // TODO: Some kind of adjustment for panes?
            NSString *s = [NSString stringWithFormat:@"\033[4;%d;%dt",
                           [delegate_ terminalWindowHeightInPixels],
                           [delegate_ terminalWindowWidthInPixels]];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case XTERMCC_REPORT_WIN_SIZE: {
            NSString *s = [NSString stringWithFormat:@"\033[8;%d;%dt",
                           [delegate_ terminalHeight],
                           [delegate_ terminalWidth]];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case XTERMCC_REPORT_SCREEN_SIZE: {
            NSString *s = [NSString stringWithFormat:@"\033[9;%d;%dt",
                           [delegate_ terminalScreenHeightInCells],
                           [delegate_ terminalScreenWidthInCells]];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case XTERMCC_REPORT_ICON_TITLE: {
            NSString *s = [NSString stringWithFormat:@"\033]L%@\033\\",
                           [delegate_ terminalIconTitle]];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case XTERMCC_REPORT_WIN_TITLE: {
            // NOTE: In versions prior to 2.9.20150415, we used "L" as the leader here, not "l".
            // That was wrong and may cause bug reports due to breaking bugward compatibility.
            // (see xterm docs)
            NSString *s = [NSString stringWithFormat:@"\033]l%@\033\\",
                           [delegate_ terminalWindowTitle]];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case XTERMCC_PUSH_TITLE: {
            switch (token.csi->p[1]) {
                case 0:
                    [delegate_ terminalPushCurrentTitleForWindow:YES];
                    [delegate_ terminalPushCurrentTitleForWindow:NO];
                    break;
                case 1:
                    [delegate_ terminalPushCurrentTitleForWindow:NO];
                    break;
                case 2:
                    [delegate_ terminalPushCurrentTitleForWindow:YES];
                    break;
                // TODO: Support 3 (UTF-8)
            }
            break;
        }
        case XTERMCC_POP_TITLE: {
            switch (token.csi->p[1]) {
                case 0:
                    [delegate_ terminalPopCurrentTitleForWindow:YES];
                    [delegate_ terminalPopCurrentTitleForWindow:NO];
                    break;
                case 1:
                    [delegate_ terminalPopCurrentTitleForWindow:NO];
                    break;
                case 2:
                    [delegate_ terminalPopCurrentTitleForWindow:YES];
                    break;
            }
            break;
        }
        // Our iTerm specific codes
        case ITERM_USER_NOTIFICATION:
            [delegate_ terminalPostUserNotification:token.string];
            break;

        case XTERMCC_MULTITOKEN_HEADER_SET_KVP:
        case XTERMCC_SET_KVP:
            [self executeXtermSetKvp:token];
            break;

        case XTERMCC_MULTITOKEN_BODY:
            // You'd get here if the user stops a file download before it finishes.
            [delegate_ terminalAppendString:token.string];
            break;

        case XTERMCC_MULTITOKEN_END:
            // Handled prior to switch.
            break;

        case VT100_BINARY_GARBAGE:
        case VT100CC_NULL:
        case VT100CC_SOH:
        case VT100_INVALID_SEQUENCE:
        case VT100_SKIP:
        case VT100_WAIT:
        case VT100CC_ACK:
        case VT100CC_DC2:
        case VT100CC_DC4:
        case VT100CC_DLE:
        case VT100CC_EM:
        case VT100CC_EOT:
        case VT100CC_ESC:
        case VT100CC_ETB:
        case VT100CC_ETX:
        case VT100CC_FS:
        case VT100CC_GS:
        case VT100CC_NAK:
        case VT100CC_RS:
        case VT100CC_STX:
        case VT100CC_SYN:
        case VT100CC_US:
        case VT100CSI_SCS:
            break;

        case VT100CSI_RESET_MODIFIERS:
            if (token.csi->count == 0) {
                [self resetSendModifiersWithSideEffects:YES];
                break;
            }
            int resource = token.csi->p[0];
            if (resource >= 0 && resource <= NUM_MODIFIABLE_RESOURCES) {
                _sendModifiers[resource] = @-1;
                [self.delegate terminalDidChangeSendModifiers];
            }
            break;

        case VT100CSI_SET_MODIFIERS: {
            if (token.csi->count == 0) {
                [self resetSendModifiersWithSideEffects:YES];
                break;
            }
            const int resource = token.csi->p[0];
            if (resource < 0 || resource >= NUM_MODIFIABLE_RESOURCES) {
                break;
            }
            int value;
            if (token.csi->count == 1) {
                value = -1;
            } else {
                value = token.csi->p[1];
                if (value < 0) {
                    break;
                }
            }
            _sendModifiers[resource] = @(value);
            [self.delegate terminalDidChangeSendModifiers];
            break;
        }

        case XTERMCC_PROPRIETARY_ETERM_EXT:
            [self executeXtermProprietaryEtermExtension:token];
            break;

        case XTERMCC_PWD_URL:
            [self executeWorkingDirectoryURL:token];
            break;

        case XTERMCC_TEXT_FOREGROUND_COLOR:
            [self executeXtermTextColorForeground:YES arg:token.string];
            break;

        case XTERMCC_TEXT_BACKGROUND_COLOR:
            [self executeXtermTextColorForeground:NO arg:token.string];
            break;

        case XTERMCC_LINK:
            [self executeLink:token];
            break;

        case XTERMCC_SET_PALETTE:
            [self executeXtermSetPalette:token];
            break;

        case XTERMCC_SET_RGB:
            [self executeXtermSetRgb:token];
            break;

        case DCS_TMUX_CODE_WRAP:
            // This is a no-op and it shouldn't happen.
            break;

        case DCS_BEGIN_SYNCHRONIZED_UPDATE:
            [self.delegate terminalSynchronizedUpdate:YES];
            break;

        case DCS_END_SYNCHRONIZED_UPDATE:
            [self.delegate terminalSynchronizedUpdate:NO];
            break;

        case DCS_REQUEST_TERMCAP_TERMINFO: {
            static NSString *const kFormat = @"%@=%@";
            BOOL ok = NO;
            NSMutableArray *parts = [NSMutableArray array];
            NSDictionary *inverseMap = [VT100DCSParser termcapTerminfoInverseNameDictionary];
            for (int i = 0; i < token.csi->count; i++) {
                NSString *stringKey = inverseMap[@(token.csi->p[i])];
                NSString *hexEncodedKey = [stringKey hexEncodedString];
                switch (token.csi->p[i]) {
                    case kDcsTermcapTerminfoRequestTerminfoName:
                        [parts addObject:[NSString stringWithFormat:kFormat,
                                          hexEncodedKey,
                                          [_termType hexEncodedString]]];
                        ok = YES;
                        break;
                    case kDcsTermcapTerminfoRequestTerminalName:
                        [parts addObject:[NSString stringWithFormat:kFormat,
                                          hexEncodedKey,
                                          [@"iTerm2" hexEncodedString]]];
                        ok = YES;
                        break;
                    case kDcsTermcapTerminfoRequestiTerm2ProfileName:
                        [parts addObject:[NSString stringWithFormat:kFormat,
                                          hexEncodedKey,
                                          [[delegate_ terminalProfileName] hexEncodedString]]];
                        ok = YES;
                        break;
                    case kDcsTermcapTerminfoRequestUnrecognizedName:
                        i = token.csi->count;
                        break;
                }
            }
            NSString *s = [NSString stringWithFormat:@"\033P%d+r%@\033\\",
                           ok ? 1 : 0,
                           [parts componentsJoinedByString:@";"]];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }

        case DCS_SIXEL:
            [delegate_ terminalAppendSixelData:token.savedData];
            break;

        case DCS_DECRQSS:
            [delegate_ terminalSendReport:[[self decrqss:token.string] dataUsingEncoding:_encoding]];
            break;

        default:
            NSLog(@"Unexpected token type %d", (int)token->type);
            break;
    }
}

- (NSString *)decrqss:(NSString *)pt {
    NSString *payload = [self decrqssPayload:pt];
    if (payload) {
        return [NSString stringWithFormat:@"%cP1$r%@%c\\", VT100CC_ESC, payload, VT100CC_ESC];
    }
    return [NSString stringWithFormat:@"%cP0$r%@%c\\", VT100CC_ESC, pt, VT100CC_ESC];
}

- (NSString *)decrqssPayload:(NSString *)pt {
    /* Per xterm's ctlseqs:
    m       ⇒  SGR
    " p     ⇒  DECSCL
    SP q    ⇒  DECSCUSR
    " q     ⇒  DECSCA
    r       ⇒  DECSTBM
    s       ⇒  DECSLRM
    t       ⇒  DECSLPP
    $ |     ⇒  DECSCPP
    * |     ⇒  DECSNLS
     */
    if ([pt isEqualToString:@"m"]) {
        NSArray<NSString *> *codes = [[self sgrCodesForGraphicRendition:graphicRendition_].allObjects sortedArrayUsingSelector:@selector(compare:)];
        return [NSString stringWithFormat:@"%@m", [codes componentsJoinedByString:@";"]];
    }
    if ([pt isEqualToString:@" q"]) {
        ITermCursorType type = CURSOR_BOX;
        BOOL blinking = YES;
        [self.delegate terminalGetCursorType:&type blinking:&blinking];
        int code = 0;
        switch (type) {
            case CURSOR_DEFAULT:
            case CURSOR_BOX:
                code = 1;
                break;
            case CURSOR_UNDERLINE:
                code = 3;
                break;
            case CURSOR_VERTICAL:
                code = 5;
                break;
        }
        if (!blinking) {
            code++;
        }
        return [NSString stringWithFormat:@"%@ q", @(code)];
    }
    return nil;
}

- (NSSet<NSString *> *)sgrCodesForCharacter:(screen_char_t)c {
    VT100GraphicRendition g = {
        .bold = c.bold,
        .blink = c.blink,
        .underline = c.underline,
        .underlineStyle = c.underlineStyle,
        .strikethrough = c.strikethrough,
        .reversed = 0,
        .faint = c.faint,
        .italic = c.italic,
        .fgColorCode = c.foregroundColor,
        .fgGreen = c.fgGreen,
        .fgBlue = c.fgBlue,
        .fgColorMode = c.foregroundColorMode,

        .bgColorCode = c.backgroundColor,
        .bgGreen = c.bgGreen,
        .bgBlue = c.bgBlue,
        .bgColorMode = c.backgroundColorMode
    };
    return [self sgrCodesForGraphicRendition:g];
}

- (NSSet<NSString *> *)sgrCodesForGraphicRendition:(VT100GraphicRendition)graphicRendition {
    NSMutableSet<NSString *> *result = [NSMutableSet set];
    [result addObject:@"0"];  // for xterm compatibility. Also makes esctest happy.
    switch (graphicRendition.fgColorMode) {
        case ColorModeNormal:
            if (graphicRendition.fgColorCode < 8) {
                [result addObject:[NSString stringWithFormat:@"%@", @(graphicRendition.fgColorCode + 30)]];
            } else if (graphicRendition.fgColorCode < 16) {
                [result addObject:[NSString stringWithFormat:@"%@", @(graphicRendition.fgColorCode + 90)]];
            } else {
                [result addObject:[NSString stringWithFormat:@"38:5:%@", @(graphicRendition.fgColorCode)]];
            }
            break;

        case ColorModeAlternate:
            switch (graphicRendition.fgColorCode) {
                case ALTSEM_DEFAULT:
                    break;
                case ALTSEM_REVERSED_DEFAULT:  // Not sure quite how to handle this, going with the simplest approach for now.
                    [result addObject:@"39"];
                    break;

                case ALTSEM_SYSTEM_MESSAGE:
                    // There is no SGR code for this case.
                    break;

                case ALTSEM_SELECTED:
                case ALTSEM_CURSOR:
                    // This isn't used as far as I can tell.
                    break;

            }
            break;

        case ColorMode24bit:
            [result addObject:[NSString stringWithFormat:@"38:2:1:%@:%@:%@",
              @(graphicRendition.fgColorCode), @(graphicRendition.fgGreen), @(graphicRendition.fgBlue)]];
            break;

        case ColorModeInvalid:
            break;
    }

    switch (graphicRendition.bgColorMode) {
        case ColorModeNormal:
            if (graphicRendition.bgColorCode < 8) {
                [result addObject:[NSString stringWithFormat:@"%@", @(graphicRendition.bgColorCode + 40)]];
            } else if (graphicRendition.bgColorCode < 16) {
                [result addObject:[NSString stringWithFormat:@"%@", @(graphicRendition.bgColorCode + 100)]];
            } else {
                [result addObject:[NSString stringWithFormat:@"48:5:%@", @(graphicRendition.bgColorCode)]];
            }
            break;

        case ColorModeAlternate:
            switch (graphicRendition.bgColorCode) {
                case ALTSEM_DEFAULT:
                    break;
                case ALTSEM_REVERSED_DEFAULT:  // Not sure quite how to handle this, going with the simplest approach for now.
                    [result addObject:@"49"];
                    break;

                case ALTSEM_SYSTEM_MESSAGE:
                    // There is no SGR code for this case.
                    break;

                case ALTSEM_SELECTED:
                case ALTSEM_CURSOR:
                    // This isn't used as far as I can tell.
                    break;

            }
            break;

        case ColorMode24bit:
            [result addObject:[NSString stringWithFormat:@"48:2:1:%@:%@:%@",
              @(graphicRendition.bgColorCode), @(graphicRendition.bgGreen), @(graphicRendition.bgBlue)]];
            break;

        case ColorModeInvalid:
            break;
    }

    if (graphicRendition.bold) {
        [result addObject:@"1"];
    }
    if (graphicRendition.faint) {
        [result addObject:@"2"];
    }
    if (graphicRendition.italic) {
        [result addObject:@"3"];
    }
    if (graphicRendition.underline) {
        switch (graphicRendition.underlineStyle) {
            case VT100UnderlineStyleSingle:
                [result addObject:@"4"];
                break;
            case VT100UnderlineStyleCurly:
                [result addObject:@"4:3"];
                break;
        }
    }
    if (graphicRendition.blink) {
        [result addObject:@"5"];
    }
    if (graphicRendition.reversed) {
        [result addObject:@"7"];
    }
    if (graphicRendition.strikethrough) {
        [result addObject:@"9"];
    }
    return result;
}

- (NSArray<NSNumber *> *)xtermParseColorArgument:(NSString *)part {
    if ([part hasPrefix:@"rgb:"]) {
        // The format of this command is "<index>;rgb:<redhex>/<greenhex>/<bluehex>", e.g. "105;rgb:00/cc/ff"
        NSString *componentsString = [part substringFromIndex:4];
        NSArray *components = [componentsString componentsSeparatedByString:@"/"];
        if (components.count == 3) {
            CGFloat colors[3];
            BOOL ok = YES;
            for (int j = 0; j < 3; j++) {
                NSScanner *scanner = [NSScanner scannerWithString:components[j]];
                unsigned int intValue;
                if (![scanner scanHexInt:&intValue]) {
                    ok = NO;
                } else {
                    ok = (intValue <= 255);
                }
                if (ok) {
                    int limit = (1 << (4 * [components[j] length])) - 1;
                    colors[j] = (CGFloat)intValue / (CGFloat)limit;
                } else {
                    break;
                }
            }
            if (ok) {
                return @[ @(colors[0]), @(colors[1]), @(colors[2]) ];
            }
        }
    }
    return nil;
}

- (void)executeXtermSetRgb:(VT100Token *)token {
    NSArray *parts = [token.string componentsSeparatedByString:@";"];
    int theIndex = 0;
    for (int i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        if ((i % 2) == 0 ) {
            theIndex = [part intValue];
        } else {
            NSArray<NSNumber *> *components = [self xtermParseColorArgument:part];
            if (components) {
                NSColor *srgb = [NSColor colorWithSRGBRed:components[0].doubleValue
                                                    green:components[1].doubleValue
                                                     blue:components[2].doubleValue
                                                    alpha:1];
                NSColor *theColor = [srgb colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
                [delegate_ terminalSetColorTableEntryAtIndex:theIndex
                                                       color:theColor];
            } else if ([part isEqualToString:@"?"]) {
                NSColor *theColor = [delegate_ terminalColorForIndex:theIndex];
                [delegate_ terminalSendReport:[self.output reportColor:theColor atIndex:theIndex prefix:@"4;"]];
            }
        }
    }
}

- (void)executeFileCommandWithValue:(NSString *)value {
    // Takes semicolon-delimited arguments.
    // File=<arg>;<arg>;...;<arg>
    // <arg> is one of:
    //   name=<base64-encoded filename>    Default: Unnamed file
    //   size=<integer file size>          Default: 0
    //   width=auto|<integer>px|<integer>  Default: auto
    //   height=auto|<integer>px|<integer> Default: auto
    //   preserveAspectRatio=<bool>        Default: yes
    //   inline=<bool>                     Default: no
    NSArray *parts = [value componentsSeparatedByString:@";"];
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"size"] = @(0);
    dict[@"width"] = @"auto";
    dict[@"height"] = @"auto";
    dict[@"preserveAspectRatio"] = @YES;
    dict[@"inline"] = @NO;
    for (NSString *part in parts) {
        NSRange eq = [part rangeOfString:@"="];
        if (eq.location != NSNotFound && eq.location > 0) {
            NSString *left = [part substringToIndex:eq.location];
            NSString *right = [part substringFromIndex:eq.location + 1];
            dict[left] = right;
        } else {
            dict[part] = @"";
        }
    }

    NSString *widthString = dict[@"width"];
    VT100TerminalUnits widthUnits = kVT100TerminalUnitsCells;
    NSString *heightString = dict[@"height"];
    VT100TerminalUnits heightUnits = kVT100TerminalUnitsCells;
    int width = [widthString intValue];
    if ([widthString isEqualToString:@"auto"]) {
        widthUnits = kVT100TerminalUnitsAuto;
    } else if ([widthString hasSuffix:@"px"]) {
        widthUnits = kVT100TerminalUnitsPixels;
    } else if ([widthString hasSuffix:@"%"]) {
        widthUnits = kVT100TerminalUnitsPercentage;
    }
    int height = [heightString intValue];
    if ([heightString isEqualToString:@"auto"]) {
        heightUnits = kVT100TerminalUnitsAuto;
    } else if ([heightString hasSuffix:@"px"]) {
        heightUnits = kVT100TerminalUnitsPixels;
    } else if ([heightString hasSuffix:@"%"]) {
        heightUnits = kVT100TerminalUnitsPercentage;
    }

    CGFloat insetTop = [dict[@"insetTop"] doubleValue];
    CGFloat insetLeft = [dict[@"insetLeft"] doubleValue];
    CGFloat insetBottom = [dict[@"insetBottom"] doubleValue];
    CGFloat insetRight = [dict[@"insetRight"] doubleValue];

    NSString *name = [dict[@"name"] stringByBase64DecodingStringWithEncoding:NSISOLatin1StringEncoding];
    if (!name) {
        name = @"Unnamed file";
    }
    if ([dict[@"inline"] boolValue]) {
        NSEdgeInsets inset = {
            .top = insetTop,
            .left = insetLeft,
            .bottom = insetBottom,
            .right = insetRight
        };
        const BOOL ok =
        [delegate_ terminalWillReceiveInlineFileNamed:name
                                               ofSize:[dict[@"size"] integerValue]
                                                width:width
                                                units:widthUnits
                                               height:height
                                                units:heightUnits
                                  preserveAspectRatio:[dict[@"preserveAspectRatio"] boolValue]
                                                inset:inset];
        if (!ok) {
            return;
        }
    } else {
        if (![delegate_ terminalWillReceiveFileNamed:name ofSize:[dict[@"size"] integerValue]]) {
            return;
        }
    }
    DLog(@"Start file receipt");
    receivingFile_ = YES;
}

- (NSArray *)keyValuePairInToken:(VT100Token *)token {
  // argument is of the form key=value
  // key: Sequence of characters not = or ^G
  // value: Sequence of characters not ^G
  NSString* argument = token.string;
  NSRange eqRange = [argument rangeOfString:@"="];
  NSString* key;
  NSString* value;
  if (eqRange.location != NSNotFound) {
    key = [argument substringToIndex:eqRange.location];;
    value = [argument substringFromIndex:eqRange.location+1];
  } else {
    key = argument;
    value = @"";
  }
  return @[ key, value ];
}

- (void)executeXtermTextColorForeground:(BOOL)foreground arg:(NSString *)arg {
    // arg is like one of:
    //   rgb:ffff/ffff/ffff
    //   ?
    const VT100TerminalColorIndex ptyIndex = foreground ? VT100TerminalColorIndexText : VT100TerminalColorIndexBackground;
    const int xtermIndex = foreground ? 10 : 11;
    if ([arg isEqualToString:@"?"]) {
        NSColor *theColor = [delegate_ terminalColorForIndex:ptyIndex];
        [delegate_ terminalSendReport:[self.output reportColor:theColor atIndex:xtermIndex prefix:@""]];
    } else {
        NSArray<NSNumber *> *components = [self xtermParseColorArgument:arg];
        if (components) {
            NSColor *srgb = [NSColor colorWithSRGBRed:components[0].doubleValue
                                                green:components[1].doubleValue
                                                 blue:components[2].doubleValue
                                                alpha:1];
            NSColor *theColor = [srgb colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
            [delegate_ terminalSetColorTableEntryAtIndex:ptyIndex
                                                   color:theColor];
        }
    }
}

- (void)executeWorkingDirectoryURL:(VT100Token *)token {
    if ([delegate_ terminalIsTrusted]) {
        [delegate_ terminalSetWorkingDirectoryURL:token.string];
    }
}

- (void)executeLink:(VT100Token *)token {
    NSInteger index = [token.string rangeOfString:@";"].location;
    if (index == NSNotFound) {
        return;
    }
    NSString *params = [token.string substringToIndex:index];
    NSString *urlString = [token.string substringFromIndex:index + 1];
    if (urlString.length > 2083) {
        return;
    }
    self.url = urlString.length ? [NSURL URLWithUserSuppliedString:urlString] : nil;
    if (self.url == nil) {
        if (_currentURLCode) {
            [delegate_ terminalWillEndLinkWithCode:_currentURLCode];
        }
        _currentURLCode = 0;
        self.urlParams = nil;
    } else {
        self.urlParams = params;
        unsigned short code = [[iTermURLStore sharedInstance] codeForURL:self.url withParams:params];
        if (code) {
            if (_currentURLCode) {
                [delegate_ terminalWillEndLinkWithCode:_currentURLCode];
            } else {
                [delegate_ terminalWillStartLinkWithCode:code];
            }
            _currentURLCode = code;
        }
    }
}

- (void)executeXtermSetKvp:(VT100Token *)token {
    if (!token.string) {
        return;
    }
    NSArray *kvp = [self keyValuePairInToken:token];
    NSString *key = kvp[0];
    NSString *value = kvp[1];
    if ([key isEqualToString:@"CursorShape"]) {
        // Value must be an integer. Bogusly, non-numbers are treated as 0.
        int shape = [value intValue];
        ITermCursorType shapeMap[] = { CURSOR_BOX, CURSOR_VERTICAL, CURSOR_UNDERLINE };
        if (shape >= 0 && shape < sizeof(shapeMap)/sizeof(*shapeMap)) {
            [delegate_ terminalSetCursorType:shapeMap[shape]];
        }
    } else if ([key isEqualToString:@"ShellIntegrationVersion"]) {
        [delegate_ terminalSetShellIntegrationVersion:value];
    } else if ([key isEqualToString:@"RemoteHost"]) {
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalSetRemoteHost:value];
        }
    } else if ([key isEqualToString:@"SetMark"]) {
        [delegate_ terminalSaveScrollPositionWithArgument:value];
    } else if ([key isEqualToString:@"StealFocus"]) {
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalStealFocus];
        }
    } else if ([key isEqualToString:@"ClearScrollback"]) {
        [delegate_ terminalClearBuffer];
    } else if ([key isEqualToString:@"CurrentDir"]) {
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalCurrentDirectoryDidChangeTo:value];
        }
    } else if ([key isEqualToString:@"SetProfile"]) {
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalProfileShouldChangeTo:(NSString *)value];
        }
    } else if ([key isEqualToString:@"AddNote"] ||  // Deprecated
               [key isEqualToString:@"AddAnnotation"]) {
        [delegate_ terminalAddNote:(NSString *)value show:YES];
    } else if ([key isEqualToString:@"AddHiddenNote"] ||  // Deprecated
               [key isEqualToString:@"AddHiddenAnnotation"]) {
        [delegate_ terminalAddNote:(NSString *)value show:NO];
    } else if ([key isEqualToString:@"HighlightCursorLine"]) {
        [delegate_ terminalSetHighlightCursorLine:value.length ? [value boolValue] : YES];
    } else if ([key isEqualToString:@"ClearCapturedOutput"]) {
        [delegate_ terminalClearCapturedOutput];
    } else if ([key isEqualToString:@"CopyToClipboard"]) {
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalSetPasteboard:value];
        }
    } else if ([key isEqualToString:@"File"]) {
        if ([delegate_ terminalIsTrusted]) {
            [self executeFileCommandWithValue:value];
        } else {
            // Enter multitoken mode to avoid showing the base64 gubbins of the image.
            receivingFile_ = YES;
            [delegate_ terminalAppendString:[NSString stringWithLongCharacter:0x1F6AB]];
        }
    } else if ([key isEqualToString:@"Copy"]) {
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalBeginCopyToPasteboard];
            _copyingToPasteboard = YES;
        }
    } else if ([key isEqualToString:@"RequestUpload"]) {
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalRequestUpload:value];
        }
    } else if ([key isEqualToString:@"BeginFile"]) {
        XLog(@"Deprecated and unsupported code BeginFile received. Use File instead.");
    } else if ([key isEqualToString:@"EndFile"]) {
        XLog(@"Deprecated and unsupported code EndFile received. Use File instead.");
    } else if ([key isEqualToString:@"EndCopy"]) {
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalCopyBufferToPasteboard];
        }
    } else if ([key isEqualToString:@"RequestAttention"]) {
        if ([value isEqualToString:@"fireworks"]) {
            [delegate_ terminalRequestAttention:VT100AttentionRequestTypeFireworks];
        } else if ([value isEqualToString:@"once"]) {
            [delegate_ terminalRequestAttention:VT100AttentionRequestTypeBounceOnceDockIcon];
        } else if ([value isEqualToString:@"flash"]) {
            [delegate_ terminalRequestAttention:VT100AttentionRequestTypeFlash];
        } else if ([value boolValue]) {
            [delegate_ terminalRequestAttention:VT100AttentionRequestTypeStartBouncingDockIcon];
        } else {
            [delegate_ terminalRequestAttention:VT100AttentionRequestTypeStopBouncingDockIcon];
        }
    } else if ([key isEqualToString:@"SetBackgroundImageFile"]) {
        DLog(@"Handle SetBackgroundImageFile");
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalSetBackgroundImageFile:value];
        }
    } else if ([key isEqualToString:@"SetBadgeFormat"]) {
        [delegate_ terminalSetBadgeFormat:value];
    } else if ([key isEqualToString:@"SetUserVar"]) {
        [delegate_ terminalSetUserVar:value];
    } else if ([key isEqualToString:@"ReportCellSize"]) {
        if ([delegate_ terminalShouldSendReport]) {
            double floatScale;
            NSSize size = [delegate_ terminalCellSizeInPoints:&floatScale];
            NSString *width = [[NSString stringWithFormat:@"%0.2f", size.width] stringByCompactingFloatingPointString];
            NSString *height = [[NSString stringWithFormat:@"%0.2f", size.height] stringByCompactingFloatingPointString];
            NSString *scale = [[NSString stringWithFormat:@"%0.2f", floatScale] stringByCompactingFloatingPointString];
            NSString *s = [NSString stringWithFormat:@"\033]1337;ReportCellSize=%@;%@;%@\033\\",
                           height, width, scale];
            [delegate_ terminalSendReport:[s dataUsingEncoding:NSUTF8StringEncoding]];
        }
    } else if ([key isEqualToString:@"UnicodeVersion"]) {
        if ([value hasPrefix:@"push"]) {
            [self pushUnicodeVersion:value];
        } else if ([value hasPrefix:@"pop"]) {
            [self popUnicodeVersion:value];
        } else if ([value isNumeric]) {
            [delegate_ terminalSetUnicodeVersion:[value integerValue]];
        }
    } else if ([key isEqualToString:@"SetColors"]) {
        for (NSString *part in [value componentsSeparatedByString:@","]) {
            NSInteger equal = [part rangeOfString:@"="].location;
            if (equal == 0 || equal == NSNotFound || equal + 1 == part.length) {
                continue;
            }
            NSString *name = [part substringToIndex:equal];
            NSString *colorString = [part substringFromIndex:equal + 1];
            [delegate_ terminalSetColorNamed:name to:colorString];
        }
    } else if ([key isEqualToString:@"SetKeyLabel"]) {
        NSInteger i = [value rangeOfString:@"="].location;
        if (i != NSNotFound && i > 0 && i + 1 <= value.length) {
            NSString *keyName = [value substringToIndex:i];
            NSString *label = [value substringFromIndex:i + 1];
            [delegate_ terminalSetLabel:label forKey:keyName];
        }
    } else if ([key isEqualToString:@"PushKeyLabels"]) {
        [delegate_ terminalPushKeyLabels:value];
    } else if ([key isEqualToString:@"PopKeyLabels"]) {
        [delegate_ terminalPopKeyLabels:value];
    } else if ([key isEqualToString:@"Disinter"]) {
        [delegate_ terminalDisinterSession];
    } else if ([key isEqualToString:@"ReportVariable"]) {
        if ([delegate_ terminalIsTrusted]) {
            NSData *valueAsData = [value dataUsingEncoding:NSISOLatin1StringEncoding];
            if (!valueAsData) {
                return;
            }
            NSData *decodedData = [[[NSData alloc] initWithBase64EncodedData:valueAsData options:0] autorelease];
            NSString *name = [decodedData stringWithEncoding:self.encoding];
            if (name && [delegate_ terminalShouldSendReportForVariable:name]) {
                NSString *encodedValue = @"";
                if (name) {
                    NSString *variableValue = [delegate_ terminalValueOfVariableNamed:name];
                    encodedValue = [[variableValue dataUsingEncoding:self.encoding] base64EncodedStringWithOptions:0];
                }
                NSString *report = [NSString stringWithFormat:@"%c]1337;ReportVariable=%@%c", VT100CC_ESC, encodedValue ?: @"", VT100CC_BEL];
                [delegate_ terminalSendReport:[report dataUsingEncoding:self.encoding]];
            }
        }
    } else if ([key isEqualToString:@"Custom"]) {
        if ([delegate_ terminalIsTrusted]) {
            // Custom=key1=value1;key2=value2;...;keyN=valueN:payload
            // ex:
            // Custom=id=SenderIdentity:MessageGoesHere
            NSInteger colon = [value rangeOfString:@":"].location;
            if (colon != NSNotFound) {
                NSArray<NSString *> *parts = [[value substringToIndex:colon] componentsSeparatedByString:@";"];
                NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
                [parts enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    NSInteger equals = [obj rangeOfString:@"="].location;
                    if (equals != NSNotFound) {
                        NSString *key = [obj substringToIndex:equals];
                        NSString *parameterValue = [obj substringFromIndex:equals + 1];
                        parameters[key] = parameterValue;
                    }
                }];
                NSString *payload = [value substringFromIndex:colon + 1];
                [delegate_ terminalCustomEscapeSequenceWithParameters:parameters
                                                              payload:payload];
            }
        }
    }
}

- (void)executeXtermSetPalette:(VT100Token *)token {
    int n;
    NSColor *theColor = [self colorForXtermCCSetPaletteString:token.string
                                               colorNumberPtr:&n];
    if (theColor) {
        switch (n) {
            case 16:
                [delegate_ terminalSetForegroundColor:theColor];
                break;
            case 17:
                [delegate_ terminalSetBackgroundColor:theColor];
                break;
            case 18:
                [delegate_ terminalSetBoldColor:theColor];
                break;
            case 19:
                [delegate_ terminalSetSelectionColor:theColor];
                break;
            case 20:
                [delegate_ terminalSetSelectedTextColor:theColor];
                break;
            case 21:
                [delegate_ terminalSetCursorColor:theColor];
                break;
            case 22:
                [delegate_ terminalSetCursorTextColor:theColor];
                break;
            default:
                [delegate_ terminalSetColorTableEntryAtIndex:n color:theColor];
                break;
        }
    }
}

- (void)executeXtermProprietaryEtermExtension:(VT100Token *)token {
    NSString* argument = token.string;
    if (![argument startsWithDigit]) {  // Support for proxy icon, if argument is empty clears current proxy icon
        if ([delegate_ terminalIsTrusted]) {
            [delegate_ terminalSetProxyIcon:argument];
        }
        return;
    }
    NSArray* parts = [argument componentsSeparatedByString:@";"];
    NSString* func = nil;
    if ([parts count] >= 1) {
        func = [parts objectAtIndex:0];
    }
    if (func) {
        if ([func isEqualToString:@"1"]) {
            // Adjusts a color modifier. This attempts to roughly follow the pattern that Eterm
            // defines.
            //
            // ESC ] 6 ; 1 ; class ; color ; attribute ; value BEL
            // ESC ] 6 ; 1 ; class ; color ; action BEL
            //
            // The "parts" array starts with "1".
            //
            // Adjusts a color modifier.
            // For the 5-argument version:
            //     class: determines which image class will have its color modifier altered:
            //       legal values: bg (background), * (all, unless a value is given),
            //       or a number 0-15 (color palette entries).
            //     color: The color component to modify.
            //       legal values: red, green, or blue.
            //     attribute: how to modify it.
            //       legal values: brightness
            //     value: the new value for this attribute.
            //       legal values: decimal integers in 0-255.
            // Only one code is accepted in the 4-argument version:
            //     class="bg"
            //     color="*"
            //     action="default"
            //     This resets the color to its default value.
            if ([parts count] == 4) {
                NSString* class = parts[1];
                NSString* color = parts[2];
                NSString* attribute = parts[3];
                if ([class isEqualToString:@"bg"] &&
                    [color isEqualToString:@"*"] &&
                    [attribute isEqualToString:@"default"]) {
                    [delegate_ terminalSetCurrentTabColor:nil];
                }
            } else if ([parts count] == 5) {
                NSString* class = parts[1];
                NSString* color = parts[2];
                NSString* attribute = parts[3];
                NSString* value = parts[4];
                if ([class isEqualToString:@"bg"] &&
                    [attribute isEqualToString:@"brightness"]) {
                    double numValue = MIN(1, ([value intValue] / 255.0));
                    if (numValue >= 0 && numValue <= 1) {
                        if ([color isEqualToString:@"red"]) {
                            [delegate_ terminalSetTabColorRedComponentTo:numValue];
                        } else if ([color isEqualToString:@"green"]) {
                            [delegate_ terminalSetTabColorGreenComponentTo:numValue];
                        } else if ([color isEqualToString:@"blue"]) {
                            [delegate_ terminalSetTabColorBlueComponentTo:numValue];
                        }
                    }
                }
            }
        }
    }
}

- (void)executeFinalTermToken:(VT100Token *)token {
    NSString *value = token.string;
    NSArray *args = [value componentsSeparatedByString:@";"];
    if (args.count == 0) {
        return;
    }

    NSString *command = args[0];
    if (command.length != 1) {
        return;
    }
    // <A>prompt<B>ls -l
    // <C>output 1
    // output 2<D>
    // <A>prompt<B>
    switch ([command characterAtIndex:0]) {
        case 'A':
            // Sequence marking the start of the command prompt (FTCS_PROMPT_START)
            self.softAlternateScreenMode = NO;  // We can reasonably assume alternate screen mode has ended if there's a prompt. Could be ssh dying, etc.
            inCommand_ = NO;  // Issue 7954
            [delegate_ terminalPromptDidStart];
            break;

        case 'B':
            // Sequence marking the start of the command read from the command prompt
            // (FTCS_COMMAND_START)
            [delegate_ terminalCommandDidStart];
            inCommand_ = YES;
            break;

        case 'C':
            // Sequence marking the end of the command read from the command prompt (FTCS_COMMAND_END)
            if (inCommand_) {
                [delegate_ terminalCommandDidEnd];
                inCommand_ = NO;
            }
            break;

        case 'D':
            // Return code of last command
            if (inCommand_) {
                [delegate_ terminalAbortCommand];
                inCommand_ = NO;
            } else if (args.count >= 2) {
                int returnCode = [args[1] intValue];
                [delegate_ terminalReturnCodeOfLastCommandWas:returnCode];
            }

        case 'E':
            // Semantic text is starting.
            // First argument:
            //    1: file name
            //    2: directory name
            //    3: pid
            if (args.count >= 2) {
                VT100TerminalSemanticTextType type = [args[1] intValue];
                if (type >= 1 && type < kVT100TerminalSemanticTextTypeMax) {
                    [delegate_ terminalSemanticTextDidStartOfType:type];
                }
            }
            break;

        case 'F':
            // Semantic text is ending.
            // First argument is same as 'D'.
            if (args.count >= 2) {
                VT100TerminalSemanticTextType type = [args[1] intValue];
                if (type >= 1 && type < kVT100TerminalSemanticTextTypeMax) {
                    [delegate_ terminalSemanticTextDidEndOfType:type];
                }
            }
            break;

        case 'G':
            // Update progress bar.
            // First argument: percentage
            // Second argument: title
            if (args.count == 1) {
                [delegate_ terminalProgressDidFinish];
            } else {
                int percent = [args[1] intValue];
                double fraction = MAX(MIN(1, 100.0 / (double)percent), 0);
                NSString *label = nil;

                if (args.count >= 3) {
                    label = args[2];
                }

                [delegate_ terminalProgressAt:fraction label:label];
            }
            break;

        case 'H':
            // Terminal command.
            [delegate_ terminalFinalTermCommand:[args subarrayWithRange:NSMakeRange(1, args.count - 1)]];
            break;
    }
}

typedef NS_ENUM(int, iTermDECRPMSetting)  {
    iTermDECRPMSettingNotRecognized = 0,
    iTermDECRPMSettingSet = 1,
    iTermDECRPMSettingReset = 2,
    iTermDECRPMSettingPermanentlySet = 3,
    iTermDECRPMSettingPermanentlyReset = 4
};

- (NSData *)decrpmForMode:(int)mode
                  setting:(iTermDECRPMSetting)setting
                     ansi:(BOOL)ansi {
    NSString *string;
    if (ansi) {
        string = [NSString stringWithFormat:@"%c[%d;%d$y", VT100CC_ESC, mode, setting];
    } else {
        string = [NSString stringWithFormat:@"%c[?%d;%d$y", VT100CC_ESC, mode, setting];
    }
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)executeANSIRequestMode:(int)mode {
    const iTermDECRPMSetting setting = [self settingForANSIRequestMode:mode];
    [self.delegate terminalSendReport:[self decrpmForMode:mode setting:setting ansi:YES]];
}

- (void)executeDECRequestMode:(int)mode {
    const iTermDECRPMSetting setting = [self settingForDECRequestMode:mode];
    [self.delegate terminalSendReport:[self decrpmForMode:mode setting:setting ansi:NO]];
}

static iTermDECRPMSetting VT100TerminalDECRPMSettingFromBoolean(BOOL flag) {
    return flag ? iTermDECRPMSettingSet : iTermDECRPMSettingReset;
};

- (iTermDECRPMSetting)settingForANSIRequestMode:(int)mode {
    switch (mode) {
        case 4:
            return VT100TerminalDECRPMSettingFromBoolean(self.insertMode);
        case 12:
            return VT100TerminalDECRPMSettingFromBoolean(self.sendReceiveMode);
    }
    return iTermDECRPMSettingPermanentlyReset;
}

- (iTermDECRPMSetting)settingForDECRequestMode:(int)mode {
    switch (mode) {
        case 1:
            return VT100TerminalDECRPMSettingFromBoolean(self.cursorMode);
        case 2:
            return VT100TerminalDECRPMSettingFromBoolean(ansiMode_);
        case 3:
            if (self.allowColumnMode) {
                return VT100TerminalDECRPMSettingFromBoolean(self.columnMode);
            } else {
                return iTermDECRPMSettingReset;
            }
        case 4:
            // Smooth vs jump scrolling. Not supported.
            break;
        case 5:
            return VT100TerminalDECRPMSettingFromBoolean(self.reverseVideo);
        case 6:
            return VT100TerminalDECRPMSettingFromBoolean(self.originMode);
        case 7:
            return VT100TerminalDECRPMSettingFromBoolean(self.wraparoundMode);
        case 8:
            return VT100TerminalDECRPMSettingFromBoolean(self.autorepeatMode);
        case 9:
            // TODO: This should send mouse x&y on button press.
            break;
        case 20:
            // This used to be the setter for "line mode", but it wasn't used and it's not
            // supported by xterm. Seemed to have something to do with CR vs LF.
            break;
        case 25:
            return VT100TerminalDECRPMSettingFromBoolean([self.delegate terminalCursorVisible]);
        case 40:
            return VT100TerminalDECRPMSettingFromBoolean(self.allowColumnMode);
        case 41:
            return VT100TerminalDECRPMSettingFromBoolean(self.moreFix);
        case 45:
            return VT100TerminalDECRPMSettingFromBoolean(self.reverseWraparoundMode);
        case 1049:
        case 47:
            // alternate screen buffer mode
            if (self.disableSmcupRmcup) {
                return iTermDECRPMSettingReset;
            } else {
                return VT100TerminalDECRPMSettingFromBoolean(self.softAlternateScreenMode);
            }

        case 69:
            return VT100TerminalDECRPMSettingFromBoolean([delegate_ terminalUseColumnScrollRegion]);

        case 1000:
        case 1001:
        case 1002:
        case 1003:
            return VT100TerminalDECRPMSettingFromBoolean(self.mouseMode + 1000 == mode);

        case 1004:
            return VT100TerminalDECRPMSettingFromBoolean(self.reportFocus && [delegate_ terminalFocusReportingAllowed]);

        case 1005:
            return VT100TerminalDECRPMSettingFromBoolean(self.mouseFormat == MOUSE_FORMAT_XTERM_EXT);

        case 1006:
            return VT100TerminalDECRPMSettingFromBoolean(self.mouseFormat == MOUSE_FORMAT_SGR);

        case 1015:
            return VT100TerminalDECRPMSettingFromBoolean(self.mouseFormat == MOUSE_FORMAT_URXVT);

        case 1036:
            return VT100TerminalDECRPMSettingFromBoolean(self.metaSendsEscape);

        case 1337:
            return VT100TerminalDECRPMSettingFromBoolean(self.reportKeyUp);

        case 2004:
            // Set bracketed paste mode
            return VT100TerminalDECRPMSettingFromBoolean(self.bracketedPasteMode);
    }
    return iTermDECRPMSettingPermanentlyReset;
}

- (NSString *)substringAfterSpaceInString:(NSString *)string {
    NSInteger i = [string rangeOfString:@" "].location;
    if (i == NSNotFound) {
        return nil;
    } else {
        return [string substringFromIndex:i + 1];
    }
}

- (void)pushUnicodeVersion:(NSString *)label {
    label = [self substringAfterSpaceInString:label];
    [_unicodeVersionStack addObject:@[ label ?: @"", @([delegate_ terminalUnicodeVersion]) ]];
}

- (void)popUnicodeVersion:(NSString *)label {
    label = [self substringAfterSpaceInString:label];
    while (_unicodeVersionStack.count > 0) {
        id entry = [[[_unicodeVersionStack lastObject] retain] autorelease];
        [_unicodeVersionStack removeLastObject];

        NSNumber *value = nil;
        NSString *entryLabel = nil;
        if ([entry isKindOfClass:[NSNumber class]]) {
            // A restored value might have just a number. New values are always an array.
            value = entry;
        } else {
            entryLabel = [entry objectAtIndex:0];
            value = [entry objectAtIndex:1];
        }
        if (label.length == 0 || [label isEqualToString:entryLabel]) {
            [delegate_ terminalSetUnicodeVersion:value.integerValue];
            return;
        }
    }
}

- (NSDictionary *)dictionaryForGraphicRendition:(VT100GraphicRendition)graphicRendition {
    return @{ kGraphicRenditionBoldKey: @(graphicRendition.bold),
              kGraphicRenditionBlinkKey: @(graphicRendition.blink),
              kGraphicRenditionUnderlineKey: @(graphicRendition.underline),
              kGraphicRenditionStrikethroughKey: @(graphicRendition.strikethrough),
              kGraphicRenditionUnderlineStyle: @(graphicRendition.underlineStyle),
              kGraphicRenditionReversedKey: @(graphicRendition.reversed),
              kGraphicRenditionFaintKey: @(graphicRendition.faint),
              kGraphicRenditionItalicKey: @(graphicRendition.italic),
              kGraphicRenditionForegroundColorCodeKey: @(graphicRendition.fgColorCode),
              kGraphicRenditionForegroundGreenKey: @(graphicRendition.fgGreen),
              kGraphicRenditionForegroundBlueKey: @(graphicRendition.fgBlue),
              kGraphicRenditionForegroundModeKey: @(graphicRendition.fgColorMode),
              kGraphicRenditionBackgroundColorCodeKey: @(graphicRendition.bgColorCode),
              kGraphicRenditionBackgroundGreenKey: @(graphicRendition.bgGreen),
              kGraphicRenditionBackgroundBlueKey: @(graphicRendition.bgBlue),
              kGraphicRenditionBackgroundModeKey: @(graphicRendition.bgColorMode) };
}

- (VT100GraphicRendition)graphicRenditionFromDictionary:(NSDictionary *)dict {
    VT100GraphicRendition graphicRendition = { 0 };
    graphicRendition.bold = [dict[kGraphicRenditionBoldKey] boolValue];
    graphicRendition.blink = [dict[kGraphicRenditionBlinkKey] boolValue];
    graphicRendition.underline = [dict[kGraphicRenditionUnderlineKey] boolValue];
    graphicRendition.strikethrough = [dict[kGraphicRenditionStrikethroughKey] boolValue];
    graphicRendition.underlineStyle = [dict[kGraphicRenditionUnderlineStyle] unsignedIntegerValue];
    graphicRendition.reversed = [dict[kGraphicRenditionReversedKey] boolValue];
    graphicRendition.faint = [dict[kGraphicRenditionFaintKey] boolValue];
    graphicRendition.italic = [dict[kGraphicRenditionItalicKey] boolValue];

    graphicRendition.fgColorCode = [dict[kGraphicRenditionForegroundColorCodeKey] intValue];
    graphicRendition.fgGreen = [dict[kGraphicRenditionForegroundGreenKey] intValue];
    graphicRendition.fgBlue = [dict[kGraphicRenditionForegroundBlueKey] intValue];
    graphicRendition.fgColorMode = [dict[kGraphicRenditionForegroundModeKey] intValue];

    graphicRendition.bgColorCode = [dict[kGraphicRenditionBackgroundColorCodeKey] intValue];
    graphicRendition.bgGreen = [dict[kGraphicRenditionBackgroundGreenKey] intValue];
    graphicRendition.bgBlue = [dict[kGraphicRenditionBackgroundBlueKey] intValue];
    graphicRendition.bgColorMode = [dict[kGraphicRenditionBackgroundModeKey] intValue];

    return graphicRendition;
}

- (NSDictionary *)dictionaryForSavedCursor:(VT100SavedCursor)savedCursor {
    NSMutableArray *lineDrawingArray = [NSMutableArray array];
    for (int i = 0; i < NUM_CHARSETS; i++) {
        [lineDrawingArray addObject:@(savedCursor.lineDrawing[i])];
    }
    return @{ kSavedCursorPositionKey: [NSDictionary dictionaryWithGridCoord:savedCursor.position],
              kSavedCursorCharsetKey: @(savedCursor.charset),
              kSavedCursorLineDrawingArrayKey: lineDrawingArray,
              kSavedCursorGraphicRenditionKey: [self dictionaryForGraphicRendition:savedCursor.graphicRendition],
              kSavedCursorOriginKey: @(savedCursor.origin),
              kSavedCursorWraparoundKey: @(savedCursor.wraparound),
              kSavedCursorUnicodeVersion: @(savedCursor.unicodeVersion) };
}

- (VT100SavedCursor)savedCursorFromDictionary:(NSDictionary *)dict {
    VT100SavedCursor savedCursor;
    savedCursor.position = [dict[kSavedCursorPositionKey] gridCoord];
    savedCursor.charset = [dict[kSavedCursorCharsetKey] intValue];
    for (int i = 0; i < NUM_CHARSETS && i < [dict[kSavedCursorLineDrawingArrayKey] count]; i++) {
        NSNumber *n = [dict[kSavedCursorLineDrawingArrayKey] objectAtIndex:i];
        savedCursor.lineDrawing[i] = [n boolValue];
    }
    savedCursor.graphicRendition = [self graphicRenditionFromDictionary:dict[kSavedCursorGraphicRenditionKey]];
    savedCursor.origin = [dict[kSavedCursorOriginKey] boolValue];
    savedCursor.wraparound = [dict[kSavedCursorWraparoundKey] boolValue];
    savedCursor.unicodeVersion = [dict[kSavedCursorUnicodeVersion] integerValue];
    return savedCursor;
}

- (NSDictionary *)stateDictionary {
    NSDictionary *dict =
        @{ kTerminalStateTermTypeKey: self.termType ?: [NSNull null],
           kTerminalStateAnswerBackStringKey: self.answerBackString ?: [NSNull null],
           kTerminalStateStringEncodingKey: @(self.encoding),
           kTerminalStateCanonicalEncodingKey: @(self.canonicalEncoding),
           kTerminalStateReportFocusKey: @(self.reportFocus),
           kTerminalStateReverseVideoKey: @(self.reverseVideo),
           kTerminalStateOriginModeKey: @(self.originMode),
           kTerminalStateMoreFixKey: @(self.moreFix),
           kTerminalStateWraparoundModeKey: @(self.wraparoundMode),
           kTerminalStateReverseWraparoundModeKey: @(self.reverseWraparoundMode),
           kTerminalStateIsAnsiKey: @(self.isAnsi),
           kTerminalStateAutorepeatModeKey: @(self.autorepeatMode),
           kTerminalStateInsertModeKey: @(self.insertMode),
           kTerminalStateSendReceiveModeKey: @(self.sendReceiveMode),
           kTerminalStateCharsetKey: @(self.charset),
           kTerminalStateMouseModeKey: @(self.mouseMode),
           kTerminalStatePreviousMouseModeKey: @(_previousMouseMode),
           kTerminalStateMouseFormatKey: @(self.mouseFormat),
           kTerminalStateCursorModeKey: @(self.cursorMode),
           kTerminalStateKeypadModeKey: @(self.keypadMode),
           kTerminalStateReportKeyUp: @(self.reportKeyUp),
           kTerminalStateMetaSendsEscape: @(self.metaSendsEscape),
           kTerminalStateSendModifiers: _sendModifiers ?: @[],
           kTerminalStateKeyReportingModeStack: _keyReportingModeStack.copy,
           kTerminalStateAllowKeypadModeKey: @(self.allowKeypadMode),
           kTerminalStateAllowPasteBracketing: @(self.allowPasteBracketing),
           kTerminalStateBracketedPasteModeKey: @(self.bracketedPasteMode),
           kTerminalStateAnsiModeKey: @(ansiMode_),
           kTerminalStateNumLockKey: @(numLock_),
           kTerminalStateGraphicRenditionKey: [self dictionaryForGraphicRendition:graphicRendition_],
           kTerminalStateMainSavedCursorKey: [self dictionaryForSavedCursor:mainSavedCursor_],
           kTerminalStateAltSavedCursorKey: [self dictionaryForSavedCursor:altSavedCursor_],
           kTerminalStateAllowColumnModeKey: @(self.allowColumnMode),
           kTerminalStateColumnModeKey: @(self.columnMode),
           kTerminalStateDisableSMCUPAndRMCUPKey: @(self.disableSmcupRmcup),
           kTerminalStateSoftAlternateScreenModeKey: @(_softAlternateScreenMode),
           kTerminalStateInCommandKey: @(inCommand_),
           kTerminalStateUnicodeVersionStack: _unicodeVersionStack,
           kTerminalStateURL: self.url ?: [NSNull null],
           kTerminalStateURLParams: self.urlParams ?: [NSNull null] };
    return [dict dictionaryByRemovingNullValues];
}

- (void)setStateFromDictionary:(NSDictionary *)dict {
    if (!dict) {
        return;
    }
    self.termType = [dict[kTerminalStateTermTypeKey] nilIfNull];

    self.answerBackString = dict[kTerminalStateAnswerBackStringKey];
    if ([self.answerBackString isKindOfClass:[NSNull class]]) {
        self.answerBackString = nil;
    }

    self.encoding = [dict[kTerminalStateStringEncodingKey] unsignedIntegerValue];
    self.canonicalEncoding = [dict[kTerminalStateCanonicalEncodingKey] unsignedIntegerValue];
    self.reportFocus = [dict[kTerminalStateReportFocusKey] boolValue];
    self.reverseVideo = [dict[kTerminalStateReverseVideoKey] boolValue];
    self.originMode = [dict[kTerminalStateOriginModeKey] boolValue];
    self.moreFix = [dict[kTerminalStateMoreFixKey] boolValue];
    self.wraparoundMode = [dict[kTerminalStateWraparoundModeKey] boolValue];
    self.reverseWraparoundMode = [dict[kTerminalStateReverseWraparoundModeKey] boolValue];
    self.isAnsi = [dict[kTerminalStateIsAnsiKey] boolValue];
    self.autorepeatMode = [dict[kTerminalStateAutorepeatModeKey] boolValue];
    self.insertMode = [dict[kTerminalStateInsertModeKey] boolValue];
    self.sendReceiveMode = [dict[kTerminalStateSendReceiveModeKey] boolValue];
    self.charset = [dict[kTerminalStateCharsetKey] intValue];
    self.mouseMode = [dict[kTerminalStateMouseModeKey] intValue];
    _previousMouseMode = [dict[kTerminalStatePreviousMouseModeKey] ?: @(MOUSE_REPORTING_NORMAL) intValue];
    self.mouseFormat = [dict[kTerminalStateMouseFormatKey] intValue];
    self.cursorMode = [dict[kTerminalStateCursorModeKey] boolValue];
    self.keypadMode = [dict[kTerminalStateKeypadModeKey] boolValue];
    self.reportKeyUp = [dict[kTerminalStateReportKeyUp] boolValue];
    self.metaSendsEscape = [dict[kTerminalStateMetaSendsEscape] boolValue];
    if (!_sendModifiers) {
        self.sendModifiers = [[@[ @-1, @-1, @-1, @-1, @-1 ] mutableCopy] autorelease];
    } else {
        while (_sendModifiers.count < NUM_MODIFIABLE_RESOURCES) {
            [_sendModifiers addObject:@-1];
        }
    }
    if ([dict[kTerminalStateKeyReportingModeStack] isKindOfClass:[NSArray class]]) {
        [_keyReportingModeStack release];
        _keyReportingModeStack = [dict[kTerminalStateKeyReportingModeStack] mutableCopy];
    }
    self.allowKeypadMode = [dict[kTerminalStateAllowKeypadModeKey] boolValue];
    self.allowPasteBracketing = [dict[kTerminalStateAllowPasteBracketing] boolValue];
    self.url = [dict[kTerminalStateURL] nilIfNull];
    self.urlParams = [dict[kTerminalStateURLParams] nilIfNull];

    self.bracketedPasteMode = [dict[kTerminalStateBracketedPasteModeKey] boolValue];
    ansiMode_ = [dict[kTerminalStateAnsiModeKey] boolValue];
    numLock_ = [dict[kTerminalStateNumLockKey] boolValue];
    graphicRendition_ = [self graphicRenditionFromDictionary:dict[kTerminalStateGraphicRenditionKey]];
    mainSavedCursor_ = [self savedCursorFromDictionary:dict[kTerminalStateMainSavedCursorKey]];
    altSavedCursor_ = [self savedCursorFromDictionary:dict[kTerminalStateAltSavedCursorKey]];
    self.allowColumnMode = [dict[kTerminalStateAllowColumnModeKey] boolValue];
    self.columnMode = [dict[kTerminalStateColumnModeKey] boolValue];
    self.disableSmcupRmcup = [dict[kTerminalStateDisableSMCUPAndRMCUPKey] boolValue];
    _softAlternateScreenMode = [dict[kTerminalStateSoftAlternateScreenModeKey] boolValue];
    inCommand_ = [dict[kTerminalStateInCommandKey] boolValue];
    [_unicodeVersionStack removeAllObjects];
    if (dict[kTerminalStateUnicodeVersionStack]) {
        [_unicodeVersionStack addObjectsFromArray:dict[kTerminalStateUnicodeVersionStack]];
    }
}

- (NSString *)sanitizedTitle:(NSString *)unsafeTitle {
    // Very long titles are slow to draw in the tabs. Limit their length and
    // cut off anything after newline since it wouldn't be visible anyway.
    NSCharacterSet *newlinesCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    NSRange newlineRange = [unsafeTitle rangeOfCharacterFromSet:newlinesCharacterSet];

    if (newlineRange.location != NSNotFound) {
        return [unsafeTitle substringToIndex:newlineRange.location];
    } else if (unsafeTitle.length > 256) {
        return [unsafeTitle substringToIndex:256];
    } else {
        return unsafeTitle;
    }
}

@end
