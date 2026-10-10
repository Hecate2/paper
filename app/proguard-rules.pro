# Keep readable stack traces (file + line numbers). Measured: dropping these attributes
# does not shrink this APK at all, so there is no reason to lose debuggability.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
