import 'company_logo_picker_stub.dart'
    if (dart.library.html) 'company_logo_picker_web.dart' as impl;

Future<String?> pickCompanyLogoDataUrl() => impl.pickCompanyLogoDataUrl();
