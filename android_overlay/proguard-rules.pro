# ML Kit text recognition (Latin) and its optional script modules referenced reflectively
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }

# Flutter / plugins
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn com.google.android.play.core.**
