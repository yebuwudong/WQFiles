//
//  WQSyntax.h
//  WQ Files
//
//  Small syntax highlighter for the text viewer: one regular expression per
//  language finds comments, strings, numbers, keywords and tags left to right
//  (so a "//" inside a string stays part of the string). Foundation only; the
//  viewer maps the token kinds to colors.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, WQSyntaxKind) {
    WQSyntaxComment = 1,
    WQSyntaxString,
    WQSyntaxKey,          // JSON keys, CSS properties, INI/YAML keys
    WQSyntaxKeyword,
    WQSyntaxNumber,
    WQSyntaxTag,          // XML/HTML tag names, CSS selectors
    WQSyntaxAttribute,    // XML attributes
    WQSyntaxPreprocessor, // #include, @media, shebang
};

typedef struct {
    NSRange range;
    WQSyntaxKind kind;
} WQSyntaxToken;

// Larger texts are shown plain (matching would take too long).
extern const NSUInteger kWQSyntaxMaxLength;

// The language for a file, from its name (and for files without an extension,
// a "#!" first line), or nil for plain text.
NSString *_Nullable wq_syntax_language(NSString *fileName, NSString *_Nullable text);

// Tokens (WQSyntaxToken structs, in text order) for text in language, or nil
// when the language is unknown, the text is too long, or cancelled() says so.
NSData *_Nullable wq_syntax_tokens(NSString *text, NSString *language, BOOL (^_Nullable cancelled)(void));

NS_ASSUME_NONNULL_END
