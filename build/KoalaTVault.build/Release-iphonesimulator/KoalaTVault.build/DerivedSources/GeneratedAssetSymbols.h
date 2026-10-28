#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"nej.KoalaTVault";

/// The "Color" asset catalog color resource.
static NSString * const ACColorNameColor AC_SWIFT_PRIVATE = @"Color";

/// The "nej_FolderIconA" asset catalog image resource.
static NSString * const ACImageNameNejFolderIconA AC_SWIFT_PRIVATE = @"nej_FolderIconA";

/// The "nej_FolderIconB" asset catalog image resource.
static NSString * const ACImageNameNejFolderIconB AC_SWIFT_PRIVATE = @"nej_FolderIconB";

/// The "nej_FolderIconC" asset catalog image resource.
static NSString * const ACImageNameNejFolderIconC AC_SWIFT_PRIVATE = @"nej_FolderIconC";

#undef AC_SWIFT_PRIVATE
