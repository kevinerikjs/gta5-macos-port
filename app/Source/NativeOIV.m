// OpenIV packages (GTA-69). A package is a zip (.oiv) or a folder holding assembly.xml and content/.
// assembly.xml lists files to add at game paths, inside archives (<archive path=...> nests), and text/xml
// edits to game files. Adds become mod files at their PC path; edits are applied to a copy of the game's
// file. Everything lands in Library/Caches/ModsExpanded, never in the player's Mods folder.
#import <Foundation/Foundation.h>
#include <zlib.h>
#include "NativeOIV.h"

void pg_log(const char *message);
static void oivLog(NSString *format,...) NS_FORMAT_FUNCTION(1,2);
static void oivLog(NSString *format,...){va_list args;va_start(args,format);NSString *s=[[NSString alloc] initWithFormat:format arguments:args];va_end(args);pg_log(s.UTF8String);}

// MARK: A small XML tree (NSXMLDocument isn't on iOS): enough for assembly.xml and the game's .xml/.meta.

@interface PGXNode : NSObject
@property(nonatomic) int kind;   // 0 element, 1 text, 2 CDATA, 3 comment
@property(nonatomic,copy) NSString *name,*text;
@property(nonatomic) NSMutableArray<NSString *> *keys,*values;
@property(nonatomic) NSMutableArray<PGXNode *> *children;
@property(nonatomic,weak) PGXNode *parent;
@end
@implementation PGXNode
- (instancetype)init{if((self=[super init])){_keys=[NSMutableArray array];_values=[NSMutableArray array];_children=[NSMutableArray array];}return self;}
- (NSString *)attr:(NSString *)key{for(NSUInteger i=0;i<_keys.count;i++)if([_keys[i] caseInsensitiveCompare:key]==NSOrderedSame)return _values[i];return nil;}
- (NSArray<PGXNode *> *)elements{NSMutableArray *list=[NSMutableArray array];for(PGXNode *n in _children)if(n.kind==0)[list addObject:n];return list;}
- (PGXNode *)child:(NSString *)name{for(PGXNode *n in _children)if(n.kind==0&&[n.name caseInsensitiveCompare:name]==NSOrderedSame)return n;return nil;}
- (NSString *)textContent{NSMutableString *s=[NSMutableString string];for(PGXNode *n in _children){if(n.kind==1||n.kind==2)[s appendString:n.text];else if(n.kind==0)[s appendString:n.textContent];}return s;}
@end

@interface PGXBuilder : NSObject <NSXMLParserDelegate>
@property(nonatomic) PGXNode *root,*current;
@end
@implementation PGXBuilder
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)name namespaceURI:(NSString *)u qualifiedName:(NSString *)q attributes:(NSDictionary *)attributes{
  PGXNode *n=[PGXNode new];n.name=name;
  for(NSString *k in [attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]){[n.keys addObject:k];[n.values addObject:attributes[k]];}
  if(!_root){_root=n;}else{n.parent=_current;[_current.children addObject:n];}
  _current=n;
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)name namespaceURI:(NSString *)u qualifiedName:(NSString *)q{_current=_current.parent;}
- (void)add:(int)kind text:(NSString *)text{
  if(!_current)return;
  PGXNode *last=_current.children.lastObject;
  if(kind==1&&last.kind==1){last.text=[last.text stringByAppendingString:text];return;}
  PGXNode *n=[PGXNode new];n.kind=kind;n.text=text;n.parent=_current;[_current.children addObject:n];
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s{[self add:1 text:s];}
- (void)parser:(NSXMLParser *)p foundIgnorableWhitespace:(NSString *)s{[self add:1 text:s];}
- (void)parser:(NSXMLParser *)p foundCDATA:(NSData *)d{[self add:2 text:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]?:@""];}
- (void)parser:(NSXMLParser *)p foundComment:(NSString *)s{[self add:3 text:s];}
@end

static PGXNode *xmlParse(NSData *data,NSString **error){
  if(!data.length){if(error)*error=@"empty file";return nil;}
  NSXMLParser *parser=[[NSXMLParser alloc] initWithData:data];PGXBuilder *builder=[PGXBuilder new];
  parser.delegate=builder;parser.shouldResolveExternalEntities=NO;
  if(![parser parse]||!builder.root){if(error)*error=parser.parserError.localizedDescription?:@"not XML";return nil;}
  return builder.root;
}
static NSString *xmlEscape(NSString *s,bool attribute){
  s=[s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
  s=[s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
  s=[s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
  return attribute?[s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"]:s;
}
static void xmlWrite(PGXNode *n,NSMutableString *out){
  if(n.kind==1){[out appendString:xmlEscape(n.text,false)];return;}
  if(n.kind==2){[out appendFormat:@"<![CDATA[%@]]>",n.text];return;}
  if(n.kind==3){[out appendFormat:@"<!--%@-->",n.text];return;}
  [out appendFormat:@"<%@",n.name];
  for(NSUInteger i=0;i<n.keys.count;i++)[out appendFormat:@" %@=\"%@\"",n.keys[i],xmlEscape(n.values[i],true)];
  if(!n.children.count){[out appendString:@" />"];return;}
  [out appendString:@">"];for(PGXNode *c in n.children)xmlWrite(c,out);[out appendFormat:@"</%@>",n.name];
}
static PGXNode *xmlCopy(PGXNode *n){
  PGXNode *c=[PGXNode new];c.kind=n.kind;c.name=n.name;c.text=n.text;c.keys=[n.keys mutableCopy];c.values=[n.values mutableCopy];
  for(PGXNode *k in n.children){PGXNode *d=xmlCopy(k);d.parent=c;[c.children addObject:d];}
  return c;
}

// XPath, the subset OIV packages use: /A/B, //B, *, and predicates [n], [@attr='v'], [Child='v'], [text()='v'].
static bool xpathPredicate(PGXNode *n,NSString *predicate,NSUInteger position){
  predicate=[predicate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSScanner *number=[NSScanner scannerWithString:predicate];NSInteger index;
  if([number scanInteger:&index]&&number.isAtEnd)return (NSInteger)position==index;
  NSRange eq=[predicate rangeOfString:@"="];if(eq.location==NSNotFound)return false;
  NSString *left=[[predicate substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSString *right=[[predicate substringFromIndex:eq.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if(right.length<2)return false;
  right=[right substringWithRange:NSMakeRange(1,right.length-2)];
  NSString *value;
  if([left hasPrefix:@"@"])value=[n attr:[left substringFromIndex:1]];
  else if([left isEqualToString:@"text()"]||[left isEqualToString:@"."])value=n.textContent;
  else {PGXNode *c=[n child:left];value=c?c.textContent:nil;}
  if(!value)return false;
  return [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:right];
}
static void xpathDescendants(PGXNode *n,NSMutableArray *out){[out addObject:n];for(PGXNode *c in n.elements)xpathDescendants(c,out);}
static NSArray<PGXNode *> *xpathSelect(PGXNode *root,NSString *path,NSString **error){
  // Split into steps, keeping "//" as a descendant marker and brackets intact.
  NSMutableArray<NSArray *> *steps=[NSMutableArray array];NSUInteger i=0,length=path.length;bool descendant=false;
  if(![path hasPrefix:@"/"])descendant=true;   // a relative path searches the whole document
  while(i<length){
    if([path characterAtIndex:i]=='/'){if(i+1<length&&[path characterAtIndex:i+1]=='/'){descendant=true;i+=2;}else i++;continue;}
    NSUInteger start=i;int depth=0;
    while(i<length){unichar c=[path characterAtIndex:i];if(c=='[')depth++;else if(c==']')depth--;else if(c=='/'&&!depth)break;i++;}
    [steps addObject:@[[path substringWithRange:NSMakeRange(start,i-start)],@(descendant)]];descendant=false;
  }
  if(!steps.count){if(error)*error=@"empty path";return @[];}
  PGXNode *document=[PGXNode new];[document.children addObject:root];
  NSArray<PGXNode *> *current=@[document];
  for(NSArray *step in steps){
    NSString *text=step[0];bool deep=[step[1] boolValue];
    NSRange bracket=[text rangeOfString:@"["];NSString *name=bracket.location==NSNotFound?text:[text substringToIndex:bracket.location];
    NSMutableArray<NSString *> *predicates=[NSMutableArray array];
    if(bracket.location!=NSNotFound){
      NSString *rest=[text substringFromIndex:bracket.location];
      while(rest.length&&[rest hasPrefix:@"["]){
        NSRange close=[rest rangeOfString:@"]"];if(close.location==NSNotFound){if(error)*error=[@"unclosed [ in " stringByAppendingString:path];return @[];}
        [predicates addObject:[rest substringWithRange:NSMakeRange(1,close.location-1)]];rest=[rest substringFromIndex:close.location+1];
      }
      if(rest.length){if(error)*error=[@"unsupported step " stringByAppendingString:text];return @[];}
    }
    if([name hasPrefix:@"@"]||[name containsString:@"("]||[name containsString:@":"]){if(error)*error=[@"unsupported step " stringByAppendingString:text];return @[];}
    NSMutableArray<PGXNode *> *next=[NSMutableArray array];
    for(PGXNode *context in current){
      NSMutableArray<PGXNode *> *pool=[NSMutableArray array];
      if(deep){NSMutableArray *all=[NSMutableArray array];for(PGXNode *c in context.elements)xpathDescendants(c,all);[pool addObjectsFromArray:all];}
      else [pool addObjectsFromArray:context.elements];
      NSMutableArray<PGXNode *> *named=[NSMutableArray array];
      for(PGXNode *c in pool)if([name isEqualToString:@"*"]||[c.name isEqualToString:name])[named addObject:c];
      for(NSString *predicate in predicates){
        NSMutableArray *kept=[NSMutableArray array];NSUInteger position=0;
        for(PGXNode *c in named){position++;if(xpathPredicate(c,predicate,position))[kept addObject:c];}
        named=kept;
      }
      for(PGXNode *c in named)if(![next containsObject:c])[next addObject:c];
    }
    current=next;
  }
  return current;   // the root element has no parent here, so it can be matched but not replaced
}

// MARK: Text edits (insert/replace/delete lines), matched the way OpenIV does: Mask (* and ?), Equal,
// StartsWith, EndsWith, Contains. Masks are tried on the line as is and trimmed.

static bool maskMatch(NSString *mask,NSString *line){
  NSMutableString *pattern=[NSMutableString stringWithString:@"^"];
  for(NSUInteger i=0;i<mask.length;i++){unichar c=[mask characterAtIndex:i];
    if(c=='*')[pattern appendString:@".*"];else if(c=='?')[pattern appendString:@"."];
    else [pattern appendString:[NSRegularExpression escapedPatternForString:[NSString stringWithCharacters:&c length:1]]];}
  [pattern appendString:@"$"];
  NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
  return re&&[re firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];
}
static bool lineMatches(NSString *line,NSString *pattern,NSString *condition){
  NSString *trimmed=[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString *c=condition.lowercaseString?:@"mask";
  if([c isEqualToString:@"equal"])return [trimmed isEqualToString:[pattern stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
  if([c isEqualToString:@"startswith"])return [trimmed hasPrefix:pattern];
  if([c isEqualToString:@"endswith"])return [trimmed hasSuffix:pattern];
  if([c isEqualToString:@"contains"])return [line containsString:pattern];
  return maskMatch(pattern,line)||maskMatch(pattern,trimmed);
}
static NSString *applyText(NSString *text,PGXNode *edits,NSString *label,NSUInteger *count){
  NSString *newline=[text containsString:@"\r\n"]?@"\r\n":@"\n";
  NSMutableArray<NSString *> *lines=[[text componentsSeparatedByString:newline] mutableCopy];
  for(PGXNode *op in edits.elements){
    NSString *pattern=[op attr:@"line"],*condition=[op attr:@"condition"],*kind=op.name.lowercaseString;
    NSArray<NSString *> *content=[[op.textContent stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if(!pattern){oivLog(@"Mods: %@: <%@> without line= is not supported, skipped.",label,op.name);continue;}
    bool done=false;
    for(NSUInteger i=0;i<lines.count;i++){
      if(!lineMatches(lines[i],pattern,condition))continue;
      if([kind isEqualToString:@"insert"]){
        bool after=[[op attr:@"where"] caseInsensitiveCompare:@"After"]==NSOrderedSame;
        [lines insertObjects:content atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(after?i+1:i,content.count)]];
        done=true;break;   // OpenIV inserts once, at the first matching line
      } else if([kind isEqualToString:@"replace"]){
        [lines replaceObjectsInRange:NSMakeRange(i,1) withObjectsFromArray:content];i+=content.count-1;done=true;
      } else if([kind isEqualToString:@"delete"]){[lines removeObjectAtIndex:i];i--;done=true;}
      else {oivLog(@"Mods: %@: text <%@> is not supported, skipped.",label,op.name);done=true;break;}
    }
    if(done)(*count)++;else oivLog(@"Mods: %@: no line matches \"%@\"; that edit did nothing.",label,pattern);
  }
  return [lines componentsJoinedByString:newline];
}

// MARK: XML edits: add (append Last/First), replace, remove, by xpath.

static NSString *applyXML(NSData *data,PGXNode *edits,NSString *label,NSUInteger *count){
  NSString *error=nil;PGXNode *root=xmlParse(data,&error);
  if(!root){oivLog(@"Mods: %@: the file to edit isn't valid XML (%@), skipped.",label,error);return nil;}
  for(PGXNode *op in edits.elements){
    NSString *path=[op attr:@"xpath"],*kind=op.name.lowercaseString;error=nil;
    if(!path){oivLog(@"Mods: %@: <%@> without xpath= is not supported, skipped.",label,op.name);continue;}
    NSArray<PGXNode *> *targets=xpathSelect(root,path,&error);
    if(error){oivLog(@"Mods: %@: xpath %@ is not supported (%@), skipped.",label,path,error);continue;}
    if(!targets.count){oivLog(@"Mods: %@: xpath %@ matches nothing; that edit did nothing.",label,path);continue;}
    for(PGXNode *target in targets){
      if([kind isEqualToString:@"add"]){
        bool first=[[op attr:@"append"] caseInsensitiveCompare:@"First"]==NSOrderedSame;NSUInteger at=first?0:target.children.count;
        for(PGXNode *c in op.children){PGXNode *d=xmlCopy(c);d.parent=target;[target.children insertObject:d atIndex:at++];}
      } else if([kind isEqualToString:@"replace"]||[kind isEqualToString:@"remove"]){
        PGXNode *parent=target.parent;
        if(!parent){oivLog(@"Mods: %@: %@ of the root element is not supported, skipped.",label,op.name);continue;}
        NSUInteger at=[parent.children indexOfObjectIdenticalTo:target];[parent.children removeObjectAtIndex:at];
        if([kind isEqualToString:@"replace"])for(PGXNode *c in op.children){PGXNode *d=xmlCopy(c);d.parent=parent;[parent.children insertObject:d atIndex:at++];}
      } else {oivLog(@"Mods: %@: xml <%@> is not supported, skipped.",label,op.name);break;}
    }
    (*count)++;
  }
  NSMutableString *out=[NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
  xmlWrite(root,out);[out appendString:@"\n"];
  return out;
}

// MARK: .oiv files are zips: stored or deflated entries, no encryption, no ZIP64.

static uint32_t rd32(const uint8_t *p){return p[0]|p[1]<<8|p[2]<<16|(uint32_t)p[3]<<24;}
static uint16_t rd16(const uint8_t *p){return p[0]|p[1]<<8;}
static bool safeRelative(NSString *path){
  if(!path.length||[path hasPrefix:@"/"]||[path containsString:@":"])return false;
  for(NSString *part in [path componentsSeparatedByString:@"/"])if([part isEqualToString:@".."])return false;
  return true;
}
static bool unzip(NSString *zipPath,NSString *target,NSString *label){
  NSData *data=[NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:nil];
  const uint8_t *b=data.bytes;NSUInteger n=data.length;
  if(n<22){oivLog(@"Mods: %@ is not a zip file, skipped.",label);return false;}
  NSUInteger end=NSNotFound;for(NSUInteger i=n-22;;i--){if(rd32(b+i)==0x06054b50){end=i;break;}if(!i||n-i>65558)break;}
  if(end==NSNotFound){oivLog(@"Mods: %@ is not a zip file, skipped.",label);return false;}
  uint32_t count=rd16(b+end+10),directory=rd32(b+end+16);
  if(directory==0xFFFFFFFF||count==0xFFFF){oivLog(@"Mods: %@ uses ZIP64, which isn't supported, skipped.",label);return false;}
  NSFileManager *fm=NSFileManager.defaultManager;NSUInteger at=directory;
  for(uint32_t k=0;k<count;k++){
    if(at+46>n||rd32(b+at)!=0x02014b50){oivLog(@"Mods: %@ has a damaged zip directory, skipped.",label);return false;}
    uint16_t flags=rd16(b+at+8),method=rd16(b+at+10),nameLength=rd16(b+at+28),extra=rd16(b+at+30),comment=rd16(b+at+32);
    uint32_t packed=rd32(b+at+20),size=rd32(b+at+24),local=rd32(b+at+42);
    if(at+46+nameLength>n){oivLog(@"Mods: %@ has a damaged zip directory, skipped.",label);return false;}
    NSString *name=[[NSString alloc] initWithBytes:b+at+46 length:nameLength encoding:NSUTF8StringEncoding]?:[[NSString alloc] initWithBytes:b+at+46 length:nameLength encoding:NSWindowsCP1252StringEncoding];
    at+=46+nameLength+extra+comment;
    name=[name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if([name hasSuffix:@"/"])continue;
    if(!safeRelative(name)){oivLog(@"Mods: %@: unsafe path %@ in the zip, skipped.",label,name);continue;}
    if(flags&1){oivLog(@"Mods: %@: %@ is encrypted, skipped.",label,name);continue;}
    if(local+30>n||rd32(b+local)!=0x04034b50){oivLog(@"Mods: %@: %@ is damaged, skipped.",label,name);continue;}
    NSUInteger start=local+30+rd16(b+local+26)+rd16(b+local+28);
    if(start+packed>n){oivLog(@"Mods: %@: %@ is damaged, skipped.",label,name);continue;}
    NSString *out=[target stringByAppendingPathComponent:name];
    [fm createDirectoryAtPath:out.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    FILE *file=fopen(out.fileSystemRepresentation,"wb");if(!file){oivLog(@"Mods: %@: couldn't write %@.",label,name);return false;}
    bool ok=true;
    if(method==0)ok=fwrite(b+start,1,packed,file)==packed;
    else if(method==8){
      z_stream z={0};ok=inflateInit2(&z,-15)==Z_OK;uint8_t buffer[1<<16];
      z.next_in=(Bytef *)(b+start);z.avail_in=packed;int status=Z_OK;
      while(ok&&status!=Z_STREAM_END){
        z.next_out=buffer;z.avail_out=sizeof buffer;status=inflate(&z,Z_NO_FLUSH);
        if(status!=Z_OK&&status!=Z_STREAM_END){ok=false;break;}
        size_t got=sizeof buffer-z.avail_out;if(got&&fwrite(buffer,1,got,file)!=got)ok=false;
        if(status==Z_OK&&!z.avail_in&&got==0){ok=false;break;}
      }
      inflateEnd(&z);if(ok&&z.total_out!=size)ok=false;
    } else {oivLog(@"Mods: %@: %@ uses zip method %u, which isn't supported, skipped.",label,name,method);fclose(file);[fm removeItemAtPath:out error:nil];continue;}
    fclose(file);
    if(!ok){oivLog(@"Mods: %@: %@ couldn't be unpacked.",label,name);[fm removeItemAtPath:out error:nil];return false;}
  }
  return true;
}

// MARK: Packages

static NSString *pcPath(NSString *path){
  path=[path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
  while([path hasPrefix:@"/"])path=[path substringFromIndex:1];
  return [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
typedef struct { NSUInteger files,edits; } PGOIVCount;
static void oivContent(PGXNode *node,NSString *prefix,NSString *content,NSString *label,NSMutableArray *adds,NSMutableArray *edits,PGOIVCount *counts){
  for(PGXNode *op in node.elements){
    NSString *kind=op.name.lowercaseString;
    if([kind isEqualToString:@"archive"]){
      NSString *path=pcPath([op attr:@"path"]?:@"");
      if(!safeRelative(path)){oivLog(@"Mods: %@: unsafe archive path %@, skipped.",label,[op attr:@"path"]);continue;}
      oivContent(op,[prefix stringByAppendingFormat:@"%@/",path],content,label,adds,edits,counts);
    } else if([kind isEqualToString:@"add"]){
      NSString *source=pcPath([op attr:@"source"]?:@""),*target=pcPath(op.textContent);
      if(!safeRelative(source)||!safeRelative(target)){oivLog(@"Mods: %@: unsafe path in <add> (%@ -> %@), skipped.",label,source,target);continue;}
      NSString *file=[content stringByAppendingPathComponent:source];BOOL directory=NO;
      if(![NSFileManager.defaultManager fileExistsAtPath:file isDirectory:&directory]||directory){
        // Packages made on Windows don't always match case: look the name up without it.
        NSString *found=nil,*folder=file.stringByDeletingLastPathComponent;
        for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil])if([name caseInsensitiveCompare:file.lastPathComponent]==NSOrderedSame)found=[folder stringByAppendingPathComponent:name];
        if(!found){oivLog(@"Mods: %@: %@ is missing from the package, skipped.",label,source);continue;}
        file=found;
      }
      [adds addObject:@[[prefix stringByAppendingString:target],file]];counts->files++;
    } else if([kind isEqualToString:@"text"]||[kind isEqualToString:@"xml"]){
      NSString *path=pcPath([op attr:@"path"]?:@"");
      if(!safeRelative(path)){oivLog(@"Mods: %@: unsafe edit path %@, skipped.",label,path);continue;}
      [edits addObject:@[[prefix stringByAppendingString:path],op,label]];
    } else oivLog(@"Mods: %@: <%@> is not supported, skipped.",label,op.name);
  }
}
static NSString *packageLabel(PGXNode *assembly,NSString *fallback){
  PGXNode *meta=[assembly child:@"metadata"];NSString *name=[[meta child:@"name"].textContent stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  PGXNode *version=[meta child:@"version"];NSMutableString *label=[NSMutableString stringWithString:name.length?name:fallback];
  if(version){
    NSString *major=[[version child:@"major"].textContent stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *minor=[[version child:@"minor"].textContent stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *tag=[[version child:@"tag"].textContent stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(major.length)[label appendFormat:@" %@.%@",major,minor.length?minor:@"0"];
    if(tag.length)[label appendFormat:@" %@",tag];
  }
  return label;
}
// The pack list is filled in automatically for add-on packs, so dlclist.xml edits that only add
// dlcpacks: items are left out (on PC they would edit update.rpf).
static bool onlyPackListItems(NSString *path,PGXNode *op){
  if(![path.lastPathComponent.lowercaseString isEqualToString:@"dlclist.xml"]||!op.elements.count)return false;
  for(PGXNode *edit in op.elements){
    NSString *kind=edit.name.lowercaseString;
    if(![kind isEqualToString:@"insert"]&&![kind isEqualToString:@"add"])return false;
    if([edit.textContent rangeOfString:@"dlcpacks" options:NSCaseInsensitiveSearch].location==NSNotFound)return false;
  }
  return true;
}

NSArray<NSArray *> *pg_oiv_expand(NSString *modsFolder,NSString *(^gameFile)(NSString *pcPath),bool gameReadable,bool *needsGame,NSArray<NSString *> **skip){
  NSFileManager *fm=NSFileManager.defaultManager;
  NSString *expanded=[[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"ModsExpanded"] stringByStandardizingPath];
  NSString *packagesDir=[expanded stringByAppendingPathComponent:@"oiv"],*editsDir=[expanded stringByAppendingPathComponent:@"edits"];
  [fm removeItemAtPath:editsDir error:nil];   // edits are redone each launch from the current files
  // Find packages: .oiv files and folders with assembly.xml next to a content/ folder. A package inside
  // another package (some .oiv files carry a stray copy of themselves) belongs to the outer one.
  NSMutableArray<NSString *> *found=[NSMutableArray array];
  NSString *root=modsFolder.stringByResolvingSymlinksInPath;
  for(NSString *relative in [fm enumeratorAtPath:root]){
    if([relative.pathComponents.firstObject.lowercaseString hasSuffix:@".off"])continue;   // a mod switched off (Settings › Mods)
    NSString *full=[root stringByAppendingPathComponent:relative];BOOL directory=NO;[fm fileExistsAtPath:full isDirectory:&directory];
    if(!directory&&[relative.pathExtension.lowercaseString isEqualToString:@"oiv"])[found addObject:relative];
    else if(!directory&&[relative.lastPathComponent.lowercaseString isEqualToString:@"assembly.xml"]){
      NSString *folder=relative.stringByDeletingLastPathComponent;BOOL contentDir=NO;
      if([fm fileExistsAtPath:[[root stringByAppendingPathComponent:folder] stringByAppendingPathComponent:@"content"] isDirectory:&contentDir]&&contentDir)[found addObject:[folder stringByAppendingString:@"/"]];
    }
  }
  [found sortUsingComparator:^NSComparisonResult(NSString *a,NSString *b){return a.length<b.length?NSOrderedAscending:a.length>b.length?NSOrderedDescending:[a compare:b];}];
  NSMutableArray<NSString *> *packages=[NSMutableArray array];
  for(NSString *p in found){
    bool nested=false;for(NSString *q in packages)if([q hasSuffix:@"/"]?[p hasPrefix:q]:false)nested=true;
    if([p isEqualToString:@"/"])continue;   // assembly.xml at the top of Mods itself: not a package folder
    if(!nested)[packages addObject:p];
  }
  *skip=packages;
  NSMutableArray<NSArray *> *result=[NSMutableArray array];
  NSMutableDictionary<NSString *,NSString *> *edited=[NSMutableDictionary dictionary];   // lowercased pc path -> current edited copy
  NSMutableSet<NSString *> *keepDirs=[NSMutableSet set];
  for(NSString *package in packages){
    NSString *full=[root stringByAppendingPathComponent:package],*folder=full,*label=package.lastPathComponent;
    if(![package hasSuffix:@"/"]){
      // Unpack once per version of the .oiv (size and date), into a folder named after it.
      NSDictionary *info=[fm attributesOfItemAtPath:full error:nil];
      NSString *safe=[[package.lastPathComponent componentsSeparatedByCharactersInSet:[NSCharacterSet alphanumericCharacterSet].invertedSet] componentsJoinedByString:@"_"];
      NSString *name=[NSString stringWithFormat:@"%@-%llu-%.0f",safe,[info[NSFileSize] unsignedLongLongValue],[info[NSFileModificationDate] timeIntervalSince1970]];
      folder=[packagesDir stringByAppendingPathComponent:name];[keepDirs addObject:name];
      NSString *marker=[folder stringByAppendingPathComponent:@".unpacked"];
      if(![fm fileExistsAtPath:marker]){
        [fm removeItemAtPath:folder error:nil];[fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        if(!unzip(full,folder,label)){[fm removeItemAtPath:folder error:nil];continue;}
        [@"" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
      }
    }
    NSString *assemblyPath=[folder stringByAppendingPathComponent:@"assembly.xml"],*error=nil;
    if(![fm fileExistsAtPath:assemblyPath])for(NSString *n in [fm contentsOfDirectoryAtPath:folder error:nil])if([n caseInsensitiveCompare:@"assembly.xml"]==NSOrderedSame)assemblyPath=[folder stringByAppendingPathComponent:n];
    PGXNode *assembly=xmlParse([NSData dataWithContentsOfFile:assemblyPath],&error);
    if(!assembly||[assembly.name caseInsensitiveCompare:@"package"]!=NSOrderedSame){oivLog(@"Mods: %@ has no readable assembly.xml (%@), skipped.",label,error?:@"not an OpenIV package");continue;}
    NSString *target=[assembly attr:@"target"];
    if(target.length&&[target caseInsensitiveCompare:@"Five"]!=NSOrderedSame){oivLog(@"Mods: %@ is a package for another game (%@), skipped.",label,target);continue;}
    NSString *title=packageLabel(assembly,label);
    PGXNode *content=[assembly child:@"content"];
    if(!content){oivLog(@"Mods: %@ has no <content>, skipped.",title);continue;}
    NSString *contentDir=[folder stringByAppendingPathComponent:@"content"];
    NSMutableArray *adds=[NSMutableArray array],*edits=[NSMutableArray array];PGOIVCount counts={0,0};
    oivContent(content,@"",contentDir,title,adds,edits,&counts);
    for(NSArray *add in adds){
      NSNumber *size=[fm attributesOfItemAtPath:add[1] error:nil][NSFileSize];
      [result addObject:@[add[0],add[1],size?:@0]];
    }
    for(NSArray *edit in edits){
      NSString *path=edit[0];PGXNode *op=edit[1];NSString *lower=path.lowercaseString;
      if(onlyPackListItems(path,op)){oivLog(@"Mods: %@: its pack list edit isn't needed; add-on packs are added to the pack list automatically.",title);continue;}
      // The file to edit: an earlier package's edit, the player's own mod file at that path, or the game's.
      NSString *base=edited[lower];
      if(!base){NSString *own=[root stringByAppendingPathComponent:path];if([fm fileExistsAtPath:own])base=own;}
      if(!base&&!gameReadable){*needsGame=true;continue;}
      if(!base)base=gameFile(path);
      if(!base){oivLog(@"Mods: %@: %@ isn't a file this game can edit (only loose files can), skipped.",title,path);continue;}
      NSData *data=[NSData dataWithContentsOfFile:base];NSUInteger before=counts.edits;NSString *output=nil;
      if([op.name.lowercaseString isEqualToString:@"text"]){
        NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]?:[[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
        if(!text){oivLog(@"Mods: %@: %@ isn't text, skipped.",title,path);continue;}
        if([text hasPrefix:@"﻿"])text=[text substringFromIndex:1];
        output=applyText(text,op,title,&counts.edits);
      } else output=applyXML(data,op,title,&counts.edits);
      if(!output||counts.edits==before)continue;
      NSString *file=[editsDir stringByAppendingPathComponent:path];
      [fm createDirectoryAtPath:file.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
      if(![output writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]){oivLog(@"Mods: %@: couldn't save the edited %@.",title,path);continue;}
      edited[lower]=file;
    }
    pg_mod_path_used([root stringByAppendingPathComponent:package].fileSystemRepresentation);   // GTA-153: this package was used
    oivLog(@"Mods: installed %@ (%lu file%s, %lu edit%s) from %@.",title,(unsigned long)counts.files,counts.files==1?"":"s",(unsigned long)counts.edits,counts.edits==1?"":"s",package.lastPathComponent);
  }
  // Edited files go in once, with every package's edits applied.
  for(NSString *lower in edited){
    NSString *file=edited[lower],*path=[file substringFromIndex:editsDir.length+1];
    NSNumber *size=[fm attributesOfItemAtPath:file error:nil][NSFileSize];
    [result addObject:@[path,file,size?:@0]];
  }
  // Unpacked copies of .oiv files that are no longer in Mods (or changed) are removed.
  for(NSString *name in [fm contentsOfDirectoryAtPath:packagesDir error:nil])if(![keepDirs containsObject:name])[fm removeItemAtPath:[packagesDir stringByAppendingPathComponent:name] error:nil];
  return result;
}
