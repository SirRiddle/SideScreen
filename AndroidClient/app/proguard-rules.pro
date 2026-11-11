# R8 rules for the release build. The app has no reflection, JNI or
# serialization of its own; CameraX and ML Kit ship their own consumer rules.
# Keep line numbers so crash traces stay readable.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
