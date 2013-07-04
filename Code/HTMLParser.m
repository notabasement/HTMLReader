//
//  HTMLParser.m
//  HTMLReader
//
//  Created by Nolan Waite on 2013-07-02.
//  Copyright (c) 2013 Nolan Waite. All rights reserved.
//

#import "HTMLParser.h"
#import "HTMLString.h"
#import "HTMLTokenizer.h"

@interface HTMLMarker : NSObject

+ (instancetype)marker;

@end

typedef NS_ENUM(NSInteger, HTMLInsertionMode)
{
    HTMLInitialInsertionMode,
    HTMLBeforeHtmlInsertionMode,
    HTMLBeforeHeadInsertionMode,
    HTMLInHeadInsertionMode,
    HTMLInHeadNoscriptInsertionMode,
    HTMLAfterHeadInsertionMode,
    HTMLInBodyInsertionMode,
    HTMLTextInsertionMode,
    HTMLInTableInsertionMode,
    HTMLInTableTextInsertionMode,
    HTMLInCaptionInsertionMode,
    HTMLInColumnGroupInsertionMode,
    HTMLInTableBodyInsertionMode,
    HTMLInRowInsertionMode,
    HTMLInCellInsertionMode,
    HTMLInSelectInsertionMode,
    HTMLInSelectInTableInsertionMode,
    HTMLInTemplateInsertionMode,
    HTMLAfterBodyInsertionMode,
    HTMLInFramesetInsertionMode,
    HTMLAfterFramesetInsertionMode,
    HTMLAfterAfterBodyInsertionMode,
    HTMLAfterAfterFramesetInsertionMode,
};

@implementation HTMLParser
{
    HTMLTokenizer *_tokenizer;
    HTMLInsertionMode _insertionMode;
    HTMLInsertionMode _originalInsertionMode;
    HTMLElementNode *_context;
    NSMutableArray *_stackOfOpenElements;
    HTMLElementNode *_headElementPointer;
    HTMLElementNode *_formElementPointer;
    HTMLDocument *_document;
    NSMutableArray *_errors;
    NSMutableArray *_tokensToReconsume;
    BOOL _framesetOkFlag;
    BOOL _ignoreNextTokenIfLineFeed;
    NSMutableArray *_listOfActiveFormattingElements;
}

- (id)initWithString:(NSString *)string context:(HTMLElementNode *)context
{
    if (!(self = [super init])) return nil;
    _tokenizer = [[HTMLTokenizer alloc] initWithString:string];
    _insertionMode = HTMLInitialInsertionMode;
    _context = context;
    _stackOfOpenElements = [NSMutableArray new];
    _errors = [NSMutableArray new];
    _tokensToReconsume = [NSMutableArray new];
    _listOfActiveFormattingElements = [NSMutableArray new];
    return self;
}

- (HTMLDocument *)document
{
    if (_document) return _document;
    _document = [HTMLDocument new];
    void (^reconsumeAll)(void) = ^{
        while (_tokensToReconsume.count > 0) {
            id again = _tokensToReconsume[0];
            [_tokensToReconsume removeObjectAtIndex:0];
            [self resume:again];
        }
    };
    for (id token in _tokenizer) {
        [self resume:token];
        reconsumeAll();
    }
    reconsumeAll();
    return _document;
}

- (NSArray *)errors
{
    return [_errors copy];
}

- (void)resume:(id)currentToken
{
    if (_ignoreNextTokenIfLineFeed) {
        _ignoreNextTokenIfLineFeed = NO;
        if ([currentToken isKindOfClass:[HTMLCharacterToken class]] &&
            [(HTMLCharacterToken *)currentToken data] == '\n')
        {
            return;
        }
    }
    switch (_insertionMode) {
        case HTMLInitialInsertionMode:
            if ([currentToken isKindOfClass:[HTMLCharacterToken class]]) {
                HTMLCharacterToken *token = currentToken;
                switch (token.data) {
                    case '\t':
                    case '\n':
                    case '\f':
                    case '\r':
                    case ' ':
                        return;
                }
            }
            if ([currentToken isKindOfClass:[HTMLCommentToken class]]) {
                HTMLCommentToken *token = currentToken;
                [self insertComment:token.data inNode:_document];
            } else if ([currentToken isKindOfClass:[HTMLDOCTYPEToken class]]) {
                HTMLDOCTYPEToken *token = currentToken;
                if (DOCTYPEIsParseError(token)) {
                    [self addParseError];
                }
                _document.doctype = [[HTMLDocumentTypeNode alloc] initWithName:token.name ?: @""
                                                                      publicId:token.publicIdentifier ?: @""
                                                                      systemId:token.systemIdentifier ?: @""];
                [_document appendChild:_document.doctype];
                _document.quirksMode = QuirksModeForDOCTYPE(token);
                [self switchInsertionMode:HTMLBeforeHtmlInsertionMode];
            } else {
                [self addParseError];
                _document.quirksMode = HTMLQuirksMode;
                [self switchInsertionMode:HTMLBeforeHtmlInsertionMode];
                [self reprocess:currentToken];
            }
            break;
            
        case HTMLBeforeHtmlInsertionMode:
            if ([currentToken isKindOfClass:[HTMLCharacterToken class]]) {
                HTMLCharacterToken *token = currentToken;
                switch (token.data) {
                    case '\t':
                    case '\n':
                    case '\f':
                    case '\r':
                    case ' ':
                        return;
                }
            }
            if ([currentToken isKindOfClass:[HTMLDOCTYPEToken class]]) {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLCommentToken class]]) {
                HTMLCommentToken *token = currentToken;
                [self insertComment:token.data inNode:_document];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"html"])
            {
                if ([currentToken selfClosingFlag]) {
                    [self addParseError];
                }
                HTMLElementNode *html = [self createElementForToken:currentToken];
                [_document appendChild:html];
                [_stackOfOpenElements addObject:html];
                [self switchInsertionMode:HTMLBeforeHeadInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       !([[currentToken tagName] isEqualToString:@"head"] ||
                         [[currentToken tagName] isEqualToString:@"body"] ||
                         [[currentToken tagName] isEqualToString:@"html"] ||
                         [[currentToken tagName] isEqualToString:@"br"]))
            {
                [self addParseError];
                return;
            } else {
                HTMLElementNode *html = [[HTMLElementNode alloc] initWithTagName:@"html"];
                [_document appendChild:html];
                [_stackOfOpenElements addObject:html];
                [self switchInsertionMode:HTMLBeforeHeadInsertionMode];
                [self reprocess:currentToken];
            }
            break;
            
        case HTMLBeforeHeadInsertionMode:
            if ([currentToken isKindOfClass:[HTMLCharacterToken class]]) {
                HTMLCharacterToken *token = currentToken;
                switch (token.data) {
                    case '\t':
                    case '\n':
                    case '\f':
                    case '\r':
                    case ' ':
                        return;
                }
            }
            if ([currentToken isKindOfClass:[HTMLCommentToken class]]) {
                HTMLCommentToken *token = currentToken;
                [self insertComment:token.data inNode:nil];
            } else if ([currentToken isKindOfClass:[HTMLDOCTYPEToken class]]) {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"html"])
            {
                [self processToken:currentToken usingRulesForInsertionMode:HTMLInBodyInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"head"])
            {
                if ([currentToken selfClosingFlag]) {
                    [self addParseError];
                }
                HTMLElementNode *head = [self insertElementForToken:currentToken];
                _headElementPointer = head;
                [self switchInsertionMode:HTMLInHeadInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       !([[currentToken tagName] isEqualToString:@"head"] ||
                         [[currentToken tagName] isEqualToString:@"body"] ||
                         [[currentToken tagName] isEqualToString:@"html"] ||
                         [[currentToken tagName] isEqualToString:@"br"]))
            {
                [self addParseError];
                return;
            } else {
                if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [currentToken selfClosingFlag]) {
                    [self addParseError];
                }
                [self insertElementForToken:[[HTMLStartTagToken alloc] initWithTagName:@"head"]];
                HTMLElementNode *head = [[HTMLElementNode alloc] initWithTagName:@"head"];
                _headElementPointer = head;
                [self switchInsertionMode:HTMLInHeadInsertionMode];
                [self reprocess:currentToken];
            }
            break;
            
        case HTMLInHeadInsertionMode:
            if ([currentToken isKindOfClass:[HTMLCharacterToken class]]) {
                HTMLCharacterToken *token = currentToken;
                switch (token.data) {
                    case '\t':
                    case '\n':
                    case '\f':
                    case '\r':
                    case ' ':
                        [self insertCharacter:token.data];
                        return;
                }
            }
            if ([currentToken isKindOfClass:[HTMLCommentToken class]]) {
                [self insertComment:[(HTMLCommentToken *)currentToken data] inNode:nil];
            } else if ([currentToken isKindOfClass:[HTMLDOCTYPEToken class]]) {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"html"])
            {
                [self processToken:currentToken usingRulesForInsertionMode:HTMLInBodyInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       ([[currentToken tagName] isEqualToString:@"base"] ||
                        [[currentToken tagName] isEqualToString:@"basefont"] ||
                        [[currentToken tagName] isEqualToString:@"bgsound"] ||
                        [[currentToken tagName] isEqualToString:@"link"]))
            {
                [self insertElementForToken:currentToken];
                [_stackOfOpenElements removeLastObject];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"meta"])
            {
                [self insertElementForToken:currentToken];
                [_stackOfOpenElements removeLastObject];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"title"])
            {
                [self insertElementForToken:currentToken];
                _tokenizer.state = HTMLTokenizerRCDATAState;
                _originalInsertionMode = _insertionMode;
                [self switchInsertionMode:HTMLTextInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       ([[currentToken tagName] isEqualToString:@"noframes"] ||
                        [[currentToken tagName] isEqualToString:@"style"]))
            {
                [self followGenericRawTextElementParsingAlgorithmForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"noscript"])
            {
                [self insertElementForToken:currentToken];
                [self switchInsertionMode:HTMLInHeadNoscriptInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"script"])
            {
                HTMLNode *adjustedInsertionLocation = [self appropriatePlaceForInsertingANode];
                HTMLElementNode *script = [self createElementForToken:currentToken];
                [adjustedInsertionLocation appendChild:script];
                [_stackOfOpenElements addObject:script];
                _tokenizer.state = HTMLTokenizerScriptDataState;
                _originalInsertionMode = _insertionMode;
                [self switchInsertionMode:HTMLTextInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"head"])
            {
                [_stackOfOpenElements removeLastObject];
                [self switchInsertionMode:HTMLAfterHeadInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"head"])
            {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       !([[currentToken tagName] isEqualToString:@"body"] ||
                         [[currentToken tagName] isEqualToString:@"html"] ||
                         [[currentToken tagName] isEqualToString:@"br"]))
            {
                [self addParseError];
                return;
            } else {
                [_stackOfOpenElements removeLastObject];
                [self switchInsertionMode:HTMLAfterHeadInsertionMode];
                [self reprocess:currentToken];
            }
            break;
            
        case HTMLInHeadNoscriptInsertionMode:
            if ([currentToken isKindOfClass:[HTMLDOCTYPEToken class]]) {
                [self addParseError];
                return;
            }
            if ([currentToken isKindOfClass:[HTMLCharacterToken class]]) {
                HTMLCharacterToken *token = currentToken;
                switch (token.data) {
                    case '\t':
                    case '\n':
                    case '\f':
                    case '\r':
                    case ' ':
                        [self processToken:currentToken usingRulesForInsertionMode:HTMLInHeadInsertionMode];
                        return;
                }
            }
            
            if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                [[currentToken tagName] isEqualToString:@"html"])
            {
                [self processToken:currentToken usingRulesForInsertionMode:HTMLInBodyInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]]
                       && [[currentToken tagName] isEqualToString:@"noscript"])
            {
                [_stackOfOpenElements removeLastObject];
                [self switchInsertionMode:HTMLInHeadInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLCommentToken class]]) {
                [self processToken:currentToken usingRulesForInsertionMode:HTMLInHeadInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [@[ @"basefont", @"bgsound", @"link", @"meta", @"noframes", @"style"]
                        containsObject:[currentToken tagName]])
            {
                [self processToken:currentToken usingRulesForInsertionMode:HTMLInHeadInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       ![[currentToken tagName] isEqualToString:@"br"])
            {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       ([[currentToken tagName] isEqualToString:@"head"] ||
                        [[currentToken tagName] isEqualToString:@"noscript"]))
            {
                [self addParseError];
                return;
            } else {
                [self addParseError];
                [_stackOfOpenElements removeLastObject];
                [self switchInsertionMode:HTMLInHeadInsertionMode];
                [self reprocess:currentToken];
            }
            break;
            
        case HTMLAfterHeadInsertionMode:
            if ([currentToken isKindOfClass:[HTMLCharacterToken class]]) {
                HTMLCharacterToken *token = currentToken;
                switch (token.data) {
                    case '\t':
                    case '\n':
                    case '\f':
                    case '\r':
                    case ' ':
                        [self insertCharacter:token.data];
                        return;
                }
            }
            if ([currentToken isKindOfClass:[HTMLCommentToken class]]) {
                [self insertComment:[(HTMLCommentToken *)currentToken data] inNode:nil];
            } else if ([currentToken isKindOfClass:[HTMLDOCTYPEToken class]]) {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"html"])
            {
                [self processToken:currentToken usingRulesForInsertionMode:HTMLInBodyInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"body"])
            {
                [self insertElementForToken:currentToken];
                _framesetOkFlag = NO;
                [self switchInsertionMode:HTMLInBodyInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"frameset"])
            {
                [self insertElementForToken:currentToken];
                [self switchInsertionMode:HTMLInFramesetInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [@[ @"base", @"basefont", @"bgsound", @"link", @"meta", @"noframes", @"script",
                        @"style", @"title" ] containsObject:[currentToken tagName]])
            {
                [self addParseError];
                [_stackOfOpenElements addObject:_headElementPointer];
                [self processToken:currentToken usingRulesForInsertionMode:HTMLInHeadInsertionMode];
                [_stackOfOpenElements removeObject:_headElementPointer];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       !([[currentToken tagName] isEqualToString:@"body"] ||
                         [[currentToken tagName] isEqualToString:@"html"] ||
                         [[currentToken tagName] isEqualToString:@"br"]))
            {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"head"])
            {
                [self addParseError];
                return;
            } else {
                [self insertElementForToken:[[HTMLStartTagToken alloc] initWithTagName:@"body"]];
                [self switchInsertionMode:HTMLInBodyInsertionMode];
                [self reprocess:currentToken];
            }
            break;
            
        case HTMLInBodyInsertionMode:
            if ([currentToken isKindOfClass:[HTMLCharacterToken class]]) {
                HTMLCharacterToken *token = currentToken;
                switch (token.data) {
                    case '\0':
                        [self addParseError];
                        return;
                    case '\t':
                    case '\n':
                    case '\f':
                    case '\r':
                    case ' ':
                        [self reconstructTheActiveFormattingElements];
                        [self insertCharacter:token.data];
                        break;
                    default:
                        [self reconstructTheActiveFormattingElements];
                        [self insertCharacter:token.data];
                        _framesetOkFlag = NO;
                        break;
                }
            } else if ([currentToken isKindOfClass:[HTMLCommentToken class]]) {
                [self insertComment:[(HTMLCommentToken *)currentToken data] inNode:nil];
            } else if ([currentToken isKindOfClass:[HTMLDOCTYPEToken class]]) {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"html"])
            {
                HTMLStartTagToken *token = currentToken;
                [self addParseError];
                HTMLElementNode *element = _stackOfOpenElements.lastObject;
                for (HTMLAttribute *attribute in token.attributes) {
                    if (![[element.attributes valueForKey:@"name"] containsObject:attribute.name]) {
                        [element addAttribute:attribute];
                    }
                }
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [@[ @"base", @"basefont", @"bgsound", @"link", @"meta", @"noframes", @"script",
                        @"style", @"title" ] containsObject:[currentToken tagName]])
            {
                [self processToken:currentToken usingRulesForInsertionMode:HTMLInHeadInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"body"])
            {
                [self addParseError];
                if (_stackOfOpenElements.count < 2 ||
                    ![[_stackOfOpenElements[1] tagName] isEqualToString:@"body"])
                {
                    return;
                }
                _framesetOkFlag = NO;
                HTMLStartTagToken *token = currentToken;
                HTMLElementNode *body = _stackOfOpenElements[1];
                for (HTMLAttribute *attribute in token.attributes) {
                    if (![[body.attributes valueForKey:@"name"] containsObject:attribute.name]) {
                        [body addAttribute:attribute];
                    }
                }
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"frameset"])
            {
                [self addParseError];
                if (_stackOfOpenElements.count < 2 ||
                    ![[_stackOfOpenElements[1] tagName] isEqualToString:@"body"])
                {
                    return;
                }
                if (!_framesetOkFlag) return;
                [_stackOfOpenElements[0] removeChild:_stackOfOpenElements[1]];
                while (_stackOfOpenElements.count > 1) {
                    [_stackOfOpenElements removeLastObject];
                }
                [self insertElementForToken:currentToken];
                [self switchInsertionMode:HTMLInFramesetInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       ([[currentToken tagName] isEqualToString:@"body"] ||
                        [[currentToken tagName] isEqualToString:@"html"]))
            {
                if (![self elementInScopeWithTagName:@"body"]) {
                    [self addParseError];
                    return;
                }
                for (HTMLElementNode *element in _stackOfOpenElements.reverseObjectEnumerator) {
                    if (![@[ @"dd", @"dt", @"li", @"optgroup", @"option", @"p", @"rp", @"rt", @"tbody", @"td",
                          @"tfoot", @"th", @"thead", @"tr", @"body", @"html" ] containsObject:element.tagName])
                    {
                        [self addParseError];
                        break;
                    }
                }
                [self switchInsertionMode:HTMLAfterBodyInsertionMode];
                if ([[currentToken tagName] isEqualToString:@"html"]) {
                    [self reprocess:currentToken];
                }
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [@[ @"address", @"article", @"aside", @"blockquote", @"center", @"details", @"dialog",
                        @"dir", @"div", @"dl", @"fieldset", @"figcaption", @"figure", @"footer", @"header",
                        @"hgroup", @"main", @"menu", @"nav", @"ol", @"p", @"section", @"summary", @"ul" ]
                        containsObject:[currentToken tagName]])
            {
                if ([self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                [self insertElementForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [@[ @"h1", @"h2", @"h3", @"h4", @"h5", @"h6" ] containsObject:[currentToken tagName]])
            {
                if ([self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                if ([@[ @"h1", @"h2", @"h3", @"h4", @"h5", @"h6" ] containsObject:
                     [_stackOfOpenElements.lastObject tagName]]) {
                    [self addParseError];
                    [_stackOfOpenElements removeLastObject];
                }
                [self insertElementForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [@[ @"pre", @"listing" ] containsObject:[currentToken tagName]])
            {
                if ([self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                [self insertElementForToken:currentToken];
                _ignoreNextTokenIfLineFeed = YES;
                _framesetOkFlag = NO;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"form"])
            {
                if (_formElementPointer) {
                    [self addParseError];
                    return;
                }
                if ([self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                HTMLElementNode *form = [self insertElementForToken:currentToken];
                _formElementPointer = form;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"li"])
            {
                _framesetOkFlag = NO;
                HTMLElementNode *node = _stackOfOpenElements.lastObject;
            loop:
                if ([node.tagName isEqualToString:@"li"]) {
                    [self generateImpliedEndTagsExceptForTagsNamed:@"li"];
                    if (![[_stackOfOpenElements.lastObject tagName] isEqualToString:@"li"]) {
                        [self addParseError];
                    }
                    while (![[_stackOfOpenElements.lastObject tagName] isEqualToString:@"li"]) {
                        [_stackOfOpenElements removeLastObject];
                    }
                    [_stackOfOpenElements removeLastObject];
                    goto done;
                }
                if ([@[ @"applet", @"area", @"article", @"aside", @"base", @"basefont", @"bgsound",
                     @"blockquote", @"body", @"br", @"button", @"caption", @"center", @"col", @"colgroup",
                     @"dd", @"details", @"dir", @"dl", @"dt", @"embed", @"fieldset", @"figcaption", @"figure",
                     @"footer", @"form", @"frame", @"frameset", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6",
                     @"head", @"header", @"hgroup", @"hr", @"html", @"iframe", @"img", @"input", @"isindex",
                     @"li", @"link", @"listing", @"main", @"marquee", @"menu", @"menuitem", @"meta", @"nav",
                     @"noembed", @"noframes", @"noscript", @"object", @"ol", @"param", @"plaintext", @"pre",
                     @"script", @"section", @"select", @"source", @"style", @"summary", @"table", @"tbody",
                     @"td", @"template", @"textarea", @"tfoot", @"th", @"thead", @"title", @"tr", @"track",
                     @"ul", @"wbr", @"xmp" ] containsObject:node.tagName])
                {
                    goto done;
                }
                node = [_stackOfOpenElements objectAtIndex:[_stackOfOpenElements indexOfObject:node] - 1];
                goto loop;
            done:
                if ([self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                [self insertElementForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       [@[ @"dd", @"dt" ] containsObject:[currentToken tagName]])
            {
                if (![self elementInScopeWithTagName:[currentToken tagName]]) {
                    [self addParseError];
                    return;
                }
                [self generateImpliedEndTagsExceptForTagsNamed:[currentToken tagName]];
                if (![[_stackOfOpenElements.lastObject tagName] isEqualToString:[currentToken tagName]]) {
                    [self addParseError];
                }
                while (![[_stackOfOpenElements.lastObject tagName] isEqualToString:[currentToken tagName]]) {
                    [_stackOfOpenElements removeLastObject];
                }
                [_stackOfOpenElements removeLastObject];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       [@[ @"h1", @"h2", @"h3", @"h4", @"h5", @"h6" ] containsObject:[currentToken tagName]])
            {
                if (![self elementInScopeWithTagNameInArray:@[ @"h1", @"h2", @"h3", @"h4", @"h5", @"h6" ]]) {
                    [self addParseError];
                    return;
                }
                [self generateImpliedEndTags];
                if (![[_stackOfOpenElements.lastObject tagName] isEqualToString:[currentToken tagName]]) {
                    [self addParseError];
                }
                while (![@[ @"h1", @"h2", @"h3", @"h4", @"h5", @"h6" ] containsObject:
                         [_stackOfOpenElements.lastObject tagName]])
                {
                    [_stackOfOpenElements removeLastObject];
                }
                [_stackOfOpenElements removeLastObject];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"a"])
            {
                for (HTMLElementNode *element in _listOfActiveFormattingElements.reverseObjectEnumerator) {
                    if ([element isEqual:[HTMLMarker marker]]) break;
                    if ([element.tagName isEqualToString:@"a"]) {
                        [self addParseError];
                        [self runAdoptionAgencyAlgorithmForTagName:@"a"];
                        [_listOfActiveFormattingElements removeObject:element];
                        [_stackOfOpenElements removeObject:element];
                        break;
                    }
                }
                [self reconstructTheActiveFormattingElements];
                HTMLElementNode *element = [self insertElementForToken:currentToken];
                [_listOfActiveFormattingElements addObject:element];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [@[ @"b", @"big", @"code", @"em", @"font", @"i", @"s", @"small", @"strike", @"strong",
                        @"tt", @"u" ] containsObject:[currentToken tagName]])
            {
                [self reconstructTheActiveFormattingElements];
                HTMLElementNode *element = [self insertElementForToken:currentToken];
                [_listOfActiveFormattingElements addObject:element];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"nobr"])
            {
                [self reconstructTheActiveFormattingElements];
                if ([self elementInScopeWithTagName:@"nobr"]) {
                    [self addParseError];
                    [self runAdoptionAgencyAlgorithmForTagName:@"nobr"];
                    [self reconstructTheActiveFormattingElements];
                }
                HTMLElementNode *element = [self insertElementForToken:currentToken];
                [_listOfActiveFormattingElements addObject:element];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       [@[ @"a", @"b", @"big", @"code", @"em", @"font", @"i", @"nobr", @"s", @"small",
                        @"strike", @"strong", @"tt", @"u" ] containsObject:[currentToken tagName]])
            {
                [self runAdoptionAgencyAlgorithmForTagName:[currentToken tagName]];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [@[ @"applet", @"marquee", @"object" ] containsObject:[currentToken tagName]])
            {
                [self reconstructTheActiveFormattingElements];
                [self insertElementForToken:currentToken];
                [_listOfActiveFormattingElements addObject:[HTMLMarker marker]];
                _framesetOkFlag = NO;
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                       [@[ @"applet", @"marquee", @"object" ] containsObject:[currentToken tagName]])
            {
                if (![self elementInScopeWithTagName:[currentToken tagName]]) {
                    [self addParseError];
                    return;
                }
                [self generateImpliedEndTags];
                if (![[_stackOfOpenElements.lastObject tagName] isEqualToString:[currentToken tagName]]) {
                    [self addParseError];
                }
                while (![[_stackOfOpenElements.lastObject tagName] isEqualToString:[currentToken tagName]]) {
                    [_stackOfOpenElements removeLastObject];
                }
                [_stackOfOpenElements removeLastObject];
                [self clearActiveFormattingElementsUpToLastMarker];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                       [[currentToken tagName] isEqualToString:@"table"])
            {
                if (_document.quirksMode != HTMLQuirksMode && [self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                [self insertElementForToken:currentToken];
                _framesetOkFlag = NO;
                [self switchInsertionMode:HTMLInTableInsertionMode];
            } else if (([currentToken isKindOfClass:[HTMLStartTagToken class]] &&
                        [@[ @"area", @"br", @"embed", @"img", @"keygen", @"wbr" ]
                         containsObject:[currentToken tagName]]) ||
                       ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                        [[currentToken tagName] isEqualToString:@"br"]))
            {
                if ([currentToken isKindOfClass:[HTMLEndTagToken class]] &&
                    [[currentToken tagName] isEqualToString:@"br"])
                {
                    [self addParseError];
                    currentToken = [[HTMLStartTagToken alloc] initWithTagName:@"br"];
                }
                [self reconstructTheActiveFormattingElements];
                [self insertElementForToken:currentToken];
                [_stackOfOpenElements removeLastObject];
                _framesetOkFlag = NO;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"input"])
            {
                HTMLStartTagToken *token = currentToken;
                [self reconstructTheActiveFormattingElements];
                [self insertElementForToken:token];
                [_stackOfOpenElements removeLastObject];
                HTMLAttribute *type;
                for (HTMLAttribute *attribute in token.attributes) {
                    if ([attribute.name isEqualToString:@"type"]) {
                        type = attribute;
                        break;
                    }
                }
                if (!type || ![type.value isEqualToString:@"hidden"]) {
                    _framesetOkFlag = NO;
                }
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [@[ @"menuitem", @"param", @"source", @"track" ] containsObject:[currentToken tagName]])
            {
                [self insertElementForToken:currentToken];
                [_stackOfOpenElements removeLastObject];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"hr"])
            {
                if ([self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                [self insertElementForToken:currentToken];
                [_stackOfOpenElements removeLastObject];
                _framesetOkFlag = NO;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"image"])
            {
                [self addParseError];
                [self reprocess:[currentToken copyWithTagName:@"img"]];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"isindex"])
            {
                [self addParseError];
                if (_formElementPointer) return;
                _framesetOkFlag = NO;
                if ([self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                HTMLElementNode *form = [self insertElementForToken:
                                         [[HTMLStartTagToken alloc] initWithTagName:@"form"]];
                _formElementPointer = form;
                HTMLStartTagToken *token = currentToken;
                for (HTMLAttribute *attribute in token.attributes) {
                    if ([attribute.name isEqualToString:@"action"]) {
                        [form addAttribute:attribute];
                    }
                }
                [self insertElementForToken:[[HTMLStartTagToken alloc] initWithTagName:@"hr"]];
                [_stackOfOpenElements removeLastObject];
                [self reconstructTheActiveFormattingElements];
                [self insertElementForToken:[[HTMLStartTagToken alloc] initWithTagName:@"label"]];
                NSString *prompt = @"This is a searchable index. Enter search keywords: ";
                for (HTMLAttribute *attribute in token.attributes) {
                    if ([attribute.name isEqualToString:@"prompt"]) {
                        prompt = attribute.value;
                        break;
                    }
                }
                EnumerateLongCharacters(prompt, ^(UTF32Char character) {
                    [self insertCharacter:character];
                });
                HTMLStartTagToken *inputToken = [[HTMLStartTagToken alloc] initWithTagName:@"input"];
                for (HTMLAttribute *attribute in token.attributes) {
                    if (![@[ @"name", @"action", @"prompt" ] containsObject:attribute.name]) {
                        [inputToken addAttributeWithName:attribute.name value:attribute.value];
                    }
                }
                [inputToken addAttributeWithName:@"name" value:@"isindex"];
                [_stackOfOpenElements removeLastObject];
                [_stackOfOpenElements removeLastObject];
                [self insertElementForToken:[[HTMLStartTagToken alloc] initWithTagName:@"hr"]];
                [_stackOfOpenElements removeLastObject];
                [_stackOfOpenElements removeLastObject];
                _formElementPointer = nil;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"textarea"])
            {
                [self insertElementForToken:currentToken];
                _ignoreNextTokenIfLineFeed = YES;
                _tokenizer.state = HTMLTokenizerRCDATAState;
                _originalInsertionMode = _insertionMode;
                _framesetOkFlag = NO;
                [self switchInsertionMode:HTMLTextInsertionMode];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"xmp"])
            {
                if ([self elementInButtonScopeWithTagName:@"p"]) {
                    [self closePElement];
                }
                [self reconstructTheActiveFormattingElements];
                _framesetOkFlag = NO;
                [self followGenericRawTextElementParsingAlgorithmForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"iframe"])
            {
                _framesetOkFlag = NO;
                [self followGenericRawTextElementParsingAlgorithmForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"noembed"])
            {
                [self followGenericRawTextElementParsingAlgorithmForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [[currentToken tagName] isEqualToString:@"select"])
            {
                [self reconstructTheActiveFormattingElements];
                [self insertElementForToken:currentToken];
                _framesetOkFlag = NO;
                switch (_insertionMode) {
                    case HTMLInTableInsertionMode:
                    case HTMLInCaptionInsertionMode:
                    case HTMLInTableBodyInsertionMode:
                    case HTMLInRowInsertionMode:
                    case HTMLInCellInsertionMode:
                        [self switchInsertionMode:HTMLInSelectInTableInsertionMode];
                        break;
                    default:
                        [self switchInsertionMode:HTMLInSelectInsertionMode];
                        break;
                }
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [@[ @"optgroup", @"option" ] containsObject:[currentToken tagName]])
            {
                if ([[_stackOfOpenElements.lastObject tagName] isEqualToString:@"option"]) {
                    [_stackOfOpenElements removeLastObject];
                }
                [self reconstructTheActiveFormattingElements];
                [self insertElementForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [@[ @"rp", @"rt" ] containsObject:[currentToken tagName]])
            {
                if ([self elementInScopeWithTagName:@"ruby"]) {
                    [self generateImpliedEndTags];
                    if (![[_stackOfOpenElements.lastObject tagName] isEqualToString:@"ruby"]) {
                        [self addParseError];
                    }
                }
                [self insertElementForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]] && [@[ @"caption", @"col", @"colgroup", @"frame", @"head", @"tbody", @"td", @"tfoot", @"th", @"thead", @"tr" ] containsObject:[currentToken tagName]])
            {
                [self addParseError];
                return;
            } else if ([currentToken isKindOfClass:[HTMLStartTagToken class]]) {
                [self reconstructTheActiveFormattingElements];
                [self insertElementForToken:currentToken];
            } else if ([currentToken isKindOfClass:[HTMLEndTagToken class]]) {
                HTMLElementNode *node = _stackOfOpenElements.lastObject;
                do {
                    if ([node.tagName isEqualToString:[currentToken tagName]]) {
                        [self generateImpliedEndTagsExceptForTagsNamed:[currentToken tagName]];
                        if (![_stackOfOpenElements.lastObject isKindOfClass:[HTMLElementNode class]] || ![[_stackOfOpenElements.lastObject tagName] isEqualToString:[currentToken tagName]]) {
                            [self addParseError];
                        }
                        while (![_stackOfOpenElements.lastObject isEqual:node]) {
                            [_stackOfOpenElements removeLastObject];
                        }
                        [_stackOfOpenElements removeLastObject];
                        break;
                    } else if ([@[ @"address", @"applet", @"area", @"article", @"aside", @"base", @"basefont", @"bgsound", @"blockquote", @"body", @"br", @"button", @"caption", @"center", @"col", @"colgroup", @"dd", @"details", @"dir", @"div", @"dl", @"dt", @"embed", @"fieldset", @"figcaption", @"figure", @"footer", @"form", @"frame", @"frameset", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"head", @"header", @"hgroup", @"hr", @"html", @"iframe", @"img", @"input", @"isindex", @"li", @"link", @"listing", @"main", @"marquee", @"menu", @"menuitem", @"meta", @"nav", @"noembed", @"noframes", @"noscript", @"object", @"ol", @"p", @"param", @"plaintext", @"pre", @"script", @"section", @"select", @"source", @"style", @"summary", @"table", @"tbody", @"td", @"template", @"textarea", @"tfoot", @"th", @"thead", @"title", @"tr", @"track", @"ul", @"wbr", @"xmp" ] containsObject:node.tagName])
                    {
                        [self addParseError];
                        return;
                    }
                    node = [_stackOfOpenElements objectAtIndex:[_stackOfOpenElements indexOfObject:node] - 1];
                } while (YES);
            }
            break;
            
        case HTMLTextInsertionMode:
        case HTMLInTableInsertionMode:
        case HTMLInTableTextInsertionMode:
        case HTMLInCaptionInsertionMode:
        case HTMLInColumnGroupInsertionMode:
        case HTMLInTableBodyInsertionMode:
        case HTMLInRowInsertionMode:
        case HTMLInCellInsertionMode:
        case HTMLInSelectInsertionMode:
        case HTMLInSelectInTableInsertionMode:
        case HTMLInTemplateInsertionMode:
        case HTMLAfterBodyInsertionMode:
        case HTMLInFramesetInsertionMode:
        case HTMLAfterFramesetInsertionMode:
        case HTMLAfterAfterBodyInsertionMode:
        case HTMLAfterAfterFramesetInsertionMode:
            // TODO
            break;
    }
}

- (void)insertComment:(NSString *)data inNode:(HTMLNode *)node
{
    if (!node) node = [self appropriatePlaceForInsertingANode];
    [node appendChild:[[HTMLCommentNode alloc] initWithData:data]];
}

- (HTMLElementNode *)appropriatePlaceForInsertingANode
{
    return _stackOfOpenElements.lastObject;
}

- (void)switchInsertionMode:(HTMLInsertionMode)insertionMode
{
    _insertionMode = insertionMode;
}

- (HTMLElementNode *)createElementForToken:(id)token
{
    HTMLElementNode *element = [[HTMLElementNode alloc] initWithTagName:[token tagName]];
    for (HTMLAttribute *attribute in [token attributes]) {
        [element addAttribute:attribute];
    }
    return element;
}

- (HTMLElementNode *)insertElementForToken:(id)token
{
    HTMLNode *adjustedInsertionLocation = [self appropriatePlaceForInsertingANode];
    HTMLElementNode *element = [self createElementForToken:token];
    [adjustedInsertionLocation appendChild:element];
    [_stackOfOpenElements addObject:element];
    return element;
}

- (void)insertCharacter:(UTF32Char)character
{
    id adjustedInsertionLocation = [self appropriatePlaceForInsertingANode];
    if ([adjustedInsertionLocation isKindOfClass:[HTMLDocument class]]) return;
    HTMLTextNode *textNode;
    if ([[[adjustedInsertionLocation childNodes] lastObject] isKindOfClass:[HTMLTextNode class]]) {
        textNode = [[adjustedInsertionLocation childNodes] lastObject];
    } else {
        textNode = [HTMLTextNode new];
        [adjustedInsertionLocation appendChild:textNode];
    }
    [textNode appendLongCharacter:character];
}

- (void)processToken:(id)token usingRulesForInsertionMode:(HTMLInsertionMode)insertionMode
{
    HTMLInsertionMode oldMode = _insertionMode;
    _insertionMode = insertionMode;
    [self resume:token];
    if (_insertionMode == insertionMode) {
        _insertionMode = oldMode;
    }
}

- (void)reprocess:(id)token
{
    [_tokensToReconsume addObject:token];
}

- (void)reconstructTheActiveFormattingElements
{
    if (_listOfActiveFormattingElements.count == 0) return;
    if ([_listOfActiveFormattingElements.lastObject isEqual:[HTMLMarker marker]]) return;
    if ([_stackOfOpenElements containsObject:_listOfActiveFormattingElements.lastObject]) return;
    NSUInteger entryIndex = _listOfActiveFormattingElements.count - 1;
rewind:
    if (entryIndex == 0) goto create;
    entryIndex--;
    if (!([_listOfActiveFormattingElements[entryIndex] isEqual:[HTMLMarker marker]] ||
          [_stackOfOpenElements containsObject:_listOfActiveFormattingElements[entryIndex]]))
    {
        goto rewind;
    }
advance:
    entryIndex++;
create:;
    HTMLElementNode *entry = _listOfActiveFormattingElements[entryIndex];
    HTMLStartTagToken *token = [[HTMLStartTagToken alloc] initWithTagName:entry.tagName];
    for (HTMLAttribute *attribute in entry.attributes) {
        [token addAttributeWithName:attribute.name value:attribute.value];
    }
    HTMLElementNode *newElement = [self insertElementForToken:token];
    [_listOfActiveFormattingElements replaceObjectAtIndex:entryIndex withObject:newElement];
    if (![_listOfActiveFormattingElements.lastObject isEqual:newElement]) {
        goto advance;
    }
}

- (HTMLElementNode *)elementInScopeWithTagName:(NSString *)tagName
{
    return [self elementInScopeWithTagNameInArray:@[ tagName ]];
}

- (HTMLElementNode *)elementInScopeWithTagNameInArray:(NSArray *)tagNames
{
    return [self elementInScopeWithTagNameInArray:tagNames additionalElementTypes:nil];
}

- (HTMLElementNode *)elementInButtonScopeWithTagName:(NSString *)tagName
{
    return [self elementInScopeWithTagNameInArray:@[ tagName ] additionalElementTypes:@[ @"button" ]];
}

- (HTMLElementNode *)elementInScopeWithTagNameInArray:(NSArray *)tagNames
                               additionalElementTypes:(NSArray *)additionalElementTypes
{
    NSArray *list = @[ @"applet", @"caption", @"html", @"table", @"td", @"th", @"marquee", @"object" ];
    if (additionalElementTypes.count > 0) {
        list = [list arrayByAddingObjectsFromArray:additionalElementTypes];
    }
    for (HTMLElementNode *node in _stackOfOpenElements.reverseObjectEnumerator) {
        if ([tagNames containsObject:node.tagName]) return node;
        if ([list containsObject:node.tagName]) return nil;
    }
    return nil;
}

- (void)closePElement
{
    [self generateImpliedEndTagsExceptForTagsNamed:@"p"];
    if ([[_stackOfOpenElements.lastObject tagName] isEqualToString:@"p"]) {
        [self addParseError];
    }
    while (![[_stackOfOpenElements.lastObject tagName] isEqualToString:@"p"]) {
        [_stackOfOpenElements removeLastObject];
    }
    [_stackOfOpenElements removeLastObject];
}

- (void)generateImpliedEndTagsExceptForTagsNamed:(NSString *)tagName
{
    NSArray *list = @[ @"dd", @"dt", @"li", @"option", @"optgroup", @"p", @"rp", @"rt" ];
    if (tagName) {
        list = [list filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self != %@", tagName]];
    }
    while ([list containsObject:[_stackOfOpenElements.lastObject tagName]]) {
        [_stackOfOpenElements removeLastObject];
    }
}

- (void)generateImpliedEndTags
{
    [self generateImpliedEndTagsExceptForTagsNamed:nil];
}

// Returns YES if the parser should "act as described in the 'any other end tag' entry below".
- (BOOL)runAdoptionAgencyAlgorithmForTagName:(NSString *)tagName
{
    for (NSInteger outerLoopCounter = 0; outerLoopCounter < 8; outerLoopCounter++) {
        HTMLElementNode *formattingElement;
        for (HTMLElementNode *element in _listOfActiveFormattingElements.reverseObjectEnumerator) {
            if ([element isEqual:[HTMLMarker marker]]) break;
            if ([element.tagName isEqualToString:tagName]) {
                formattingElement = element;
                break;
            }
        }
        if (!formattingElement) return YES;
        if (![_stackOfOpenElements containsObject:formattingElement]) {
            [self addParseError];
            [_listOfActiveFormattingElements removeObject:formattingElement];
            return NO;
        }
        if (![self isElementInScope:formattingElement]) {
            [self addParseError];
            return NO;
        }
        if (![_stackOfOpenElements.lastObject isEqual:formattingElement]) {
            [self addParseError];
        }
        HTMLElementNode *furthestBlock;
        for (NSUInteger i = [_stackOfOpenElements indexOfObject:formattingElement]; i < _stackOfOpenElements.count; i++) {
            if ([@[ @"address", @"applet", @"area", @"article", @"aside", @"base", @"basefont", @"bgsound", @"blockquote", @"body", @"br", @"button", @"caption", @"center", @"col", @"colgroup", @"dd", @"details", @"dir", @"div", @"dl", @"dt", @"embed", @"fieldset", @"figcaption", @"figure", @"footer", @"form", @"frame", @"frameset", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"head", @"header", @"hgroup", @"hr", @"html", @"iframe", @"img", @"input", @"isindex", @"li", @"link", @"listing", @"main", @"marquee", @"menu", @"menuitem", @"meta", @"nav", @"noembed", @"noframes", @"noscript", @"object", @"ol", @"p", @"param", @"plaintext", @"pre", @"script", @"section", @"select", @"source", @"style", @"summary", @"table", @"tbody", @"td", @"template", @"textarea", @"tfoot", @"th", @"thead", @"title", @"tr", @"track", @"ul", @"wbr", @"xmp" ] containsObject:[_stackOfOpenElements[i] tagName]])
            {
                furthestBlock = _stackOfOpenElements[i];
                break;
            }
        }
        if (!furthestBlock) {
            while (![_stackOfOpenElements.lastObject isEqual:formattingElement]) {
                [_stackOfOpenElements removeLastObject];
            }
            [_stackOfOpenElements removeLastObject];
            [_listOfActiveFormattingElements removeObject:formattingElement];
            return NO;
        }
        HTMLElementNode *commonAncestor = [_stackOfOpenElements objectAtIndex:
                                           [_stackOfOpenElements indexOfObject:formattingElement] - 1];
        NSUInteger bookmark = [_listOfActiveFormattingElements indexOfObject:formattingElement];
        HTMLElementNode *node = furthestBlock, *lastNode = furthestBlock;
        NSUInteger nodeIndex = [_stackOfOpenElements indexOfObject:node];
        for (NSInteger innerLoopCounter = 0; innerLoopCounter < 3; innerLoopCounter++) {
            node = [_stackOfOpenElements objectAtIndex:--nodeIndex];
            if (![_listOfActiveFormattingElements containsObject:node]) {
                [_stackOfOpenElements removeObject:node];
                continue;
            }
            if ([node isEqual:formattingElement]) break;
            HTMLElementNode *clone = [node copy];
            [_listOfActiveFormattingElements replaceObjectAtIndex:[_listOfActiveFormattingElements indexOfObject:node]
                                                       withObject:clone];
            [_stackOfOpenElements replaceObjectAtIndex:[_stackOfOpenElements indexOfObject:node]
                                            withObject:clone];
            node = clone;
            if ([lastNode isEqual:furthestBlock]) {
                bookmark = [_listOfActiveFormattingElements indexOfObject:node] + 1;
            }
            [node appendChild:lastNode];
            lastNode = node;
        }
        [self insertNode:lastNode atAppropriatePlaceWithOverrideTarget:commonAncestor];
        HTMLElementNode *formattingClone = [formattingElement copy];
        for (id childNode in formattingElement.childNodes) {
            [formattingClone appendChild:childNode];
        }
        [furthestBlock appendChild:formattingClone];
        if ([_listOfActiveFormattingElements indexOfObject:formattingElement] < bookmark) {
            bookmark--;
        }
        [_listOfActiveFormattingElements removeObject:formattingElement];
        [_listOfActiveFormattingElements insertObject:formattingClone atIndex:bookmark];
        [_stackOfOpenElements removeObject:formattingElement];
        [_stackOfOpenElements insertObject:formattingClone
                                   atIndex:[_stackOfOpenElements indexOfObject:furthestBlock] + 1];
    }
    return NO;
}

- (BOOL)isElementInScope:(HTMLElementNode *)element
{
    NSArray *list = @[ @"applet", @"caption", @"html", @"table", @"td", @"th", @"marquee", @"object" ];
    for (HTMLElementNode *node in _stackOfOpenElements.reverseObjectEnumerator) {
        if ([node isEqual:element]) return YES;
        if ([list containsObject:node.tagName]) return NO;
    }
    return NO;
}

- (void)insertNode:(id)node atAppropriatePlaceWithOverrideTarget:(id)overrideTarget
{
    HTMLElementNode *target = overrideTarget ?: _stackOfOpenElements.lastObject;
    [target appendChild:node];
}

- (void)clearActiveFormattingElementsUpToLastMarker
{
    while (![_listOfActiveFormattingElements.lastObject isEqual:[HTMLMarker marker]]) {
        [_listOfActiveFormattingElements removeLastObject];
    }
    [_listOfActiveFormattingElements removeLastObject];
}

- (void)followGenericRawTextElementParsingAlgorithmForToken:(id)token
{
    [self insertElementForToken:token];
    _tokenizer.state = HTMLTokenizerRAWTEXTState;
    _originalInsertionMode = _insertionMode;
    [self switchInsertionMode:HTMLTextInsertionMode];
}

static BOOL DOCTYPEIsParseError(HTMLDOCTYPEToken *t)
{
    NSString *name = t.name, *public = t.publicIdentifier, *system = t.systemIdentifier;
    if (![name isEqualToString:@"html"]) return YES;
    if ([public isEqualToString:@"-//W3C//DTD HTML 4.0//EN"] &&
        (!system || [system isEqualToString:@"http://www.w3.org/TR/REC-html40/strict.dtd"]))
    {
        return NO;
    }
    if ([public isEqualToString:@"-//W3C//DTD HTML 4.01//EN"] &&
        (!system || [system isEqualToString:@"http://www.w3.org/TR/html4/strict.dtd"]))
    {
        return NO;
    }
    if ([public isEqualToString:@"-//W3C//DTD XHTML 1.0 Strict//EN"] &&
        [system isEqualToString:@"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"])
    {
        return NO;
    }
    if ([public isEqualToString:@"-//W3C//DTD XHTML 1.1//EN"] &&
        [system isEqualToString:@"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd"])
    {
        return NO;
    }
    if (public) return YES;
    if (system && ![system isEqualToString:@"about:legacy-compat"]) return YES;
    return NO;
}

static HTMLDocumentQuirksMode QuirksModeForDOCTYPE(HTMLDOCTYPEToken *t)
{
    if (t.forceQuirks) return HTMLQuirksMode;
    if (![t.name isEqualToString:@"html"]) return HTMLQuirksMode;
    static NSString * Prefixes[] = {
        @"+//Silmaril//dtd html Pro v0r11 19970101//",
        @"-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//",
        @"-//AS//DTD HTML 3.0 asWedit + extensions//",
        @"-//IETF//DTD HTML 2.0 Level 1//",
        @"-//IETF//DTD HTML 2.0 Level 2//",
        @"-//IETF//DTD HTML 2.0 Strict Level 1//",
        @"-//IETF//DTD HTML 2.0 Strict Level 2//",
        @"-//IETF//DTD HTML 2.0 Strict//",
        @"-//IETF//DTD HTML 2.0//",
        @"-//IETF//DTD HTML 2.1E//",
        @"-//IETF//DTD HTML 3.0//",
        @"-//IETF//DTD HTML 3.2 Final//",
        @"-//IETF//DTD HTML 3.2//",
        @"-//IETF//DTD HTML 3//",
        @"-//IETF//DTD HTML Level 0//",
        @"-//IETF//DTD HTML Level 1//",
        @"-//IETF//DTD HTML Level 2//",
        @"-//IETF//DTD HTML Level 3//",
        @"-//IETF//DTD HTML Strict Level 0//",
        @"-//IETF//DTD HTML Strict Level 1//",
        @"-//IETF//DTD HTML Strict Level 2//",
        @"-//IETF//DTD HTML Strict Level 3//",
        @"-//IETF//DTD HTML Strict//",
        @"-//IETF//DTD HTML//",
        @"-//Metrius//DTD Metrius Presentational//",
        @"-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//",
        @"-//Microsoft//DTD Internet Explorer 2.0 HTML//",
        @"-//Microsoft//DTD Internet Explorer 2.0 Tables//",
        @"-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//",
        @"-//Microsoft//DTD Internet Explorer 3.0 HTML//",
        @"-//Microsoft//DTD Internet Explorer 3.0 Tables//",
        @"-//Netscape Comm. Corp.//DTD HTML//",
        @"-//Netscape Comm. Corp.//DTD Strict HTML//",
        @"-//O'Reilly and Associates//DTD HTML 2.0//",
        @"-//O'Reilly and Associates//DTD HTML Extended 1.0//",
        @"-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//",
        @"-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::extensions to HTML 4.0//",
        @"-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//",
        @"-//Spyglass//DTD HTML 2.0 Extended//",
        @"-//SQ//DTD HTML 2.0 HoTMetaL + extensions//",
        @"-//Sun Microsystems Corp.//DTD HotJava HTML//",
        @"-//Sun Microsystems Corp.//DTD HotJava Strict HTML//",
        @"-//W3C//DTD HTML 3 1995-03-24//",
        @"-//W3C//DTD HTML 3.2 Draft//",
        @"-//W3C//DTD HTML 3.2 Final//",
        @"-//W3C//DTD HTML 3.2//",
        @"-//W3C//DTD HTML 3.2S Draft//",
        @"-//W3C//DTD HTML 4.0 Frameset//",
        @"-//W3C//DTD HTML 4.0 Transitional//",
        @"-//W3C//DTD HTML Experimental 19960712//",
        @"-//W3C//DTD HTML Experimental 970421//",
        @"-//W3C//DTD W3 HTML//",
        @"-//W3O//DTD W3 HTML 3.0//",
        @"-//WebTechs//DTD Mozilla HTML 2.0//",
        @"-//WebTechs//DTD Mozilla HTML//",
    };
    for (size_t i = 0; i < sizeof(Prefixes) / sizeof(Prefixes[0]); i++) {
        if ([t.publicIdentifier hasPrefix:Prefixes[i]]) {
            return HTMLQuirksMode;
        }
    }
    if ([t.publicIdentifier isEqualToString:@"-//W3O//DTD W3 HTML Strict 3.0//EN//"] ||
        [t.publicIdentifier isEqualToString:@"-/W3C/DTD HTML 4.0 Transitional/EN"] ||
        [t.publicIdentifier isEqualToString:@"HTML"])
    {
        return HTMLQuirksMode;
    }
    if ([t.systemIdentifier isEqualToString:@"http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd"]) {
        return HTMLQuirksMode;
    }
    if (!t.systemIdentifier) {
        if ([t.publicIdentifier hasPrefix:@"-//W3C//DTD HTML 4.01 Frameset//"] ||
            [t.publicIdentifier hasPrefix:@"-//W3C//DTD HTML 4.01 Transitional//"])
        {
            return HTMLQuirksMode;
        }
    }
    if ([t.publicIdentifier hasPrefix:@"-//W3C//DTD XHTML 1.0 Frameset//"] ||
        [t.publicIdentifier hasPrefix:@"-//W3C//DTD XHTML 1.0 Transitional//"])
    {
        return HTMLLimitedQuirksMode;
    }
    if (t.systemIdentifier) {
        if ([t.publicIdentifier hasPrefix:@"-//W3C//DTD HTML 4.01 Frameset//"] ||
            [t.publicIdentifier hasPrefix:@"-//W3C//DTD HTML 4.01 Transitional//"])
        {
            return HTMLLimitedQuirksMode;
        }
    }
    return HTMLNoQuirksMode;
}

- (void)addParseError
{
    [_errors addObject:[NSNull null]];
}

@end

@implementation HTMLMarker

+ (instancetype)marker
{
    static HTMLMarker *marker;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        marker = [self new];
    });
    return marker;
}

#pragma mark NSObject

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[HTMLMarker class]];
}

- (NSUInteger)hash
{
    // Random constant.
    return 2358723968;
}

@end
