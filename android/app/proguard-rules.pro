# ONNX Runtime's native JNI layer resolves these Java types and members by
# their original binary names. R8 renaming/removal makes FindClass return null
# and Android aborts the whole process from OrtSession.run; this is not a
# catchable Java exception. Keep the complete package as required by the
# official ONNX Runtime Android integration documentation.
-keep class ai.onnxruntime.** { *; }
