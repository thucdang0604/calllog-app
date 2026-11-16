# Flutter / AndroidX / app entry points
-keep class androidx.annotation.Keep { *; }
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <fields>;
}
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <methods>;
}

# Keep plugin bridge class & its callbacks intact
-keep class com.example.call_log_manager.CallLogManagerPlugin { *; }
-keep class com.example.call_log_manager.AppSettingsStore { *; }
-keep enum com.example.call_log_manager.BarcodeScanOutcome { *; }
