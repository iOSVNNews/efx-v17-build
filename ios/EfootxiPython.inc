// CPython 3.12 embedded bridge. Runtime/assets are assembled locally from pinned inputs.
#ifdef EFOOTXI_IOS
#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>
#include <CommonCrypto/CommonCryptor.h>
static void (^gEfootxiProgress)(NSString*, double);
static PyObject* nativeProgress(PyObject*, PyObject* args) {
  const char* message; double fraction;
  if (!PyArg_ParseTuple(args, "sd", &message, &fraction)) return nullptr;
  NSString* text = [NSString stringWithUTF8String:message];
  dispatch_async(dispatch_get_main_queue(), ^{ if (gEfootxiProgress) gEfootxiProgress(text, fraction); });
  Py_RETURN_NONE;
}

static PyObject* nativeRestartRequired(PyObject*, PyObject*) {
  dispatch_async(dispatch_get_main_queue(), ^{
    static BOOL shown = NO;
    if (shown) return;
    UIWindow* window = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes)
      if ([scene isKindOfClass:UIWindowScene.class])
        for (UIWindow* candidate in ((UIWindowScene*)scene).windows)
          if (candidate.isKeyWindow) window = candidate;
    UIViewController* controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if (!controller) return;
    shown = YES;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Đồ họa iOS đã sẵn sàng"
        message:@"Đóng hẳn game rồi mở lại để áp dụng. Dữ liệu cầu thủ được giữ nguyên."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
  });
  Py_RETURN_NONE;
}

static PyObject* nativeAES(PyObject*, PyObject* args) {
  int encrypt; const char *key, *iv, *input; Py_ssize_t keySize, ivSize, size;
  if (!PyArg_ParseTuple(args, "iy#y#y#", &encrypt, &key, &keySize, &iv, &ivSize, &input, &size)) return nullptr;
  if (keySize != 32 || ivSize != 16 || size % 16) { PyErr_SetString(PyExc_ValueError, "AES-256-CBC requires key=32, iv=16, block-aligned input"); return nullptr; }
  PyObject* output = PyBytes_FromStringAndSize(nullptr, size+16);
  if (!output) return nullptr;
  size_t written = 0;
  CCCryptorStatus status = CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES, 0, key, keySize, iv,
      input, size, PyBytes_AS_STRING(output), size+16, &written);
  if (status != kCCSuccess) { Py_DECREF(output); PyErr_Format(PyExc_RuntimeError, "CommonCrypto AES error %d", status); return nullptr; }
  if (_PyBytes_Resize(&output, written) < 0) return nullptr;
  return output;
}
static PyMethodDef efootxiMethods[] = {{"aes_cbc", nativeAES, METH_VARARGS, nullptr},
  {"progress", nativeProgress, METH_VARARGS, nullptr},
  {"restart_required", nativeRestartRequired, METH_NOARGS, nullptr}, {nullptr,nullptr,0,nullptr}};
static struct PyModuleDef efootxiModule = {PyModuleDef_HEAD_INIT, "_efootxi_native", nullptr, -1, efootxiMethods};
PyMODINIT_FUNC PyInit__efootxi_native() { return PyModule_Create(&efootxiModule); }

static std::mutex gPythonMu;
static PyObject* gPythonServe;
static bool gPythonAttempted = false;
static NSString* gPythonFailure;

static void initializeEfootxi() {
  BackendIOScope backendIO;
  gPythonAttempted = true;
  NSString* bundle = NSBundle.mainBundle.bundlePath;
  NSString* python = [bundle stringByAppendingPathComponent:@"python"];
  NSString* resources = [bundle stringByAppendingPathComponent:@"efootxi"];
  NSString* support = [[gSupport stringByDeletingLastPathComponent] stringByAppendingPathComponent:
    [gEfootxiDataMode isEqualToString:@"china-data"] ? @"Efootxi2027-China" : @"Efootxi2027-Global"];
  [NSFileManager.defaultManager createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:nil];
  if (PyImport_AppendInittab("_efootxi_native", PyInit__efootxi_native) < 0) { gPythonFailure=@"Cannot register native Python module"; return; }
  PyConfig config; PyConfig_InitIsolatedConfig(&config);
  config.write_bytecode=0; config.install_signal_handlers=0; config.parse_argv=0; config.use_environment=0;
  config.buffered_stdio=0;
  config.configure_c_stdio=1;
  PyStatus status = PyConfig_SetBytesString(&config, &config.home, python.fileSystemRepresentation);
  if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.executable, NSBundle.mainBundle.executablePath.fileSystemRepresentation);
  for (NSString* path in @[[python stringByAppendingPathComponent:@"lib/python3.12"],
      [python stringByAppendingPathComponent:@"lib/python3.12/lib-dynload"], [resources stringByAppendingPathComponent:@"bridge"]]) {
    if (PyStatus_Exception(status)) break;
    wchar_t* wide = Py_DecodeLocale(path.fileSystemRepresentation, nullptr);
    if (!wide) { gPythonFailure=@"Invalid Python module path"; PyConfig_Clear(&config); return; }
    status = PyWideStringList_Append(&config.module_search_paths, wide); PyMem_RawFree(wide);
  }
  config.module_search_paths_set=1;
  if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
  if (PyStatus_Exception(status)) gPythonFailure = [NSString stringWithUTF8String:status.err_msg ?: "Python initialization failed"];
  PyConfig_Clear(&config);
  if (!Py_IsInitialized()) return;
  PyObject* module = PyImport_ImportModule("efootxi_ios");
  PyObject* result = module ? PyObject_CallMethod(module, "configure", "sss", resources.fileSystemRepresentation,
      support.fileSystemRepresentation, gSessionDir.fileSystemRepresentation) : nullptr;
  if (result) {
    Py_DECREF(result); gPythonServe = PyObject_GetAttrString(module, "serve");
  }
  if (!gPythonServe) {
    PyObject *type=nullptr, *value=nullptr, *traceback=nullptr;
    PyErr_Fetch(&type, &value, &traceback);
    PyErr_NormalizeException(&type, &value, &traceback);
    PyObject* message = value ? PyObject_Str(value) : nullptr;
    NSString* errStr = message ? [NSString stringWithUTF8String:PyUnicode_AsUTF8(message)] : @"Unknown startup error";
    Py_XDECREF(message);
    gPythonFailure = [NSString stringWithFormat:@"Efootxi startup failed: %@", errStr];
    ZLog(@"[EFOOTXI] Python startup error: %@", errStr);
    PyErr_Restore(type, value, traceback);
    PyErr_Print();
  }
  Py_XDECREF(module);
  PyEval_SaveThread();
  ZLog(@"[EFOOTXI] Python startup %@", gPythonServe ? @"ready" : gPythonFailure);
}

static NSString* efootxiPrepareResources() {
  BackendIOScope backendIO;
  std::lock_guard<std::mutex> lock(gPythonMu);
  if (!gPythonAttempted) initializeEfootxi();
  if (!gPythonServe) return gPythonFailure ?: @"Python unavailable";
  PyGILState_STATE gil = PyGILState_Ensure();
  PyObject* module = PyImport_ImportModule("efootxi_ios");
  PyObject* result = module ? PyObject_CallMethod(module, "prepare_data", "sss", gEfootxiDataMode.UTF8String,
      gDocs.fileSystemRepresentation, gOriginalDocuments.fileSystemRepresentation) : nullptr;
  NSString* error = nil;
  if (!result) {
    PyObject *type=nullptr, *value=nullptr, *traceback=nullptr;
    PyErr_Fetch(&type, &value, &traceback); PyErr_NormalizeException(&type, &value, &traceback);
    PyObject* message = value ? PyObject_Str(value) : nullptr;
    error = message ? [NSString stringWithUTF8String:PyUnicode_AsUTF8(message)] : @"Resource preparation failed";
    Py_XDECREF(message); PyErr_Restore(type, value, traceback); PyErr_Print();
  }
  Py_XDECREF(result); Py_XDECREF(module); PyGILState_Release(gil);
  return error;
}

static NSData* efootxiServe(NSString* method, NSString* path, NSData* body, NSInteger* status, NSString** mime) {
  BackendIOScope backendIO;
  std::lock_guard<std::mutex> lock(gPythonMu);
  if (!gPythonAttempted) initializeEfootxi();
  if (!gPythonServe) { *status=500; *mime=@"text/plain"; return [(gPythonFailure ?: @"Python unavailable") dataUsingEncoding:NSUTF8StringEncoding]; }
  PyGILState_STATE gil = PyGILState_Ensure();
  PyObject* result = PyObject_CallFunction(gPythonServe, "ssy#", method.UTF8String, path.UTF8String, body.bytes ?: "", (Py_ssize_t)body.length);
  NSData* data = nil;
  int code=500; const char *type=nullptr, *bytes=nullptr; Py_ssize_t length=0;
  if (result && PyArg_ParseTuple(result, "isy#", &code, &type, &bytes, &length)) {
    *status=code; *mime=[NSString stringWithUTF8String:type]; data=[NSData dataWithBytes:bytes length:length];
  } else {
    PyErr_Print(); *status=500; *mime=@"text/plain"; data=[@"Efootxi request failed; see session logs" dataUsingEncoding:NSUTF8StringEncoding];
    ZLog(@"[EFOOTXI_ERROR] %@", path);
  }
  Py_XDECREF(result); PyGILState_Release(gil); return data;
}
#endif
