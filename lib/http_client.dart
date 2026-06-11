import 'package:http/http.dart' as http;

import 'http_client_default.dart'
    if (dart.library.html) 'http_client_web.dart' as platform;

http.Client createAppHttpClient() => platform.createAppHttpClient();
