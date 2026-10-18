-keep class ph.yooh.novpn.** { *; }

# --- SSH engine (vendored trilead) ---------------------------------------
# BlockCipherFactory resolves cipher implementations by STRING name
# (Class.forName("com.trilead.ssh2.crypto.cipher.AES")), and the JCA resolves
# the EdDSA provider's algorithms the same way. R8 cannot see those references,
# so without these keeps it renamed/shrank the classes and every release build
# died right after KEX with "Fatal error during MAC startup!" →
# "Key exchange was not finished, connection is closed." Debug builds
# (minifyEnabled false) were unaffected, which is what made it look like a
# server-side/legacy-algorithm problem.
-keep class com.trilead.ssh2.** { *; }
-keep class com.cbtunnel.plus.** { *; }
-keep class net.sourceforge.** { *; }

# EdDSASecurityProvider registers its implementations as class-name strings.
-keep class net.i2p.crypto.eddsa.** { *; }
-keep class net.i2p.crypto.eddsa.EdDSASecurityProvider { *; }
-keepclassmembers class * extends java.security.Provider {
    <init>(...);
}

# EdDSAEngine.engineInitVerify() references the JDK-only sun.security.x509.X509Key
# on a fallback path that Android never takes. Before the keep rules above, R8
# shrank the whole class away and the reference went unnoticed — meaning
# ssh-ed25519 host keys could never have worked in a release build either. Now
# that the class is kept, R8 sees the dangling reference and fails the build, so
# it has to be silenced explicitly.
-dontwarn sun.security.x509.**
-dontwarn sun.security.**

# ---------------------------------------------------------------------------
# DEX protection: aggressive R8
#
# These make the DEX far harder to decompile/read:
#  - repackageclasses: flatten the whole (kept) package hierarchy into one,
#    removing meaningful package names from the DEX.
#  - allowaccessmodification: let R8 inline/merge across access boundaries
#    (more aggressive, smaller, harder to follow).
#  - overloadaggressively + mergeinterfacesaggressively: rename overloads to
#    the same name / merge interface methods — classic obfuscation.
#  - optimizationpasses: grind the bytecode a few extra times.
#
# Everything reachable from the entry points is still kept by R8's usual
# reachability; only code referenced via reflection is listed in -keep rules
# above/below. Native (JNI/SWIG), SSH and eddsa are already -keep'd.
-optimizationpasses 5
-repackageclasses 'sensei0'
-allowaccessmodification
-overloadaggressively
-mergeinterfacesaggressively

# Flutter/Android entry points: keep class names for manifest/embedding, but let
# R8 rename/inline the actual implementation methods.
-keep class com.sensei.tunnel.MainActivity { public <init>(...); }
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Manifest entry point: the class name and constructor must survive, internals do
# not need readable names in release smali.
-keep class com.sensei.tunnel.SenseiTunnelVpnService { <init>(...); }

# JNI_OnLoad does FindClass("com/sensei/tunnel/AppSecurity") and RegisterNatives
# by method name, so only this class name and its native method names are fixed.
# Public Kotlin wrappers and every other com.sensei.tunnel helper can be renamed.
-keep class com.sensei.tunnel.AppSecurity { native <methods>; }
