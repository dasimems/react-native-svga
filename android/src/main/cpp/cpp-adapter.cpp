#include <jni.h>
#include "svgaOnLoad.hpp"

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return margelo::nitro::svga::initialize(vm);
}
