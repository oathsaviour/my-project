# Keep Flutter & app classes
-keep class com.universal.filetransfer.** { *; }
-keepattributes Signature,InnerClasses,EnclosingMethod

# Keep mobile_scanner, CameraX, and ML Kit barcode scanning classes (prevents null getClass() crash in release)
-keep class dev.steenbakker.mobile_scanner.** { *; }
-keep class com.google.mlkit.** { *; }
-keep class com.google.mlkit.vision.barcode.** { *; }
-keepclassmembers class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-keep class androidx.camera.** { *; }
-keepclassmembers class androidx.camera.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn androidx.camera.**
