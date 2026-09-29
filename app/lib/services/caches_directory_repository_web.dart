import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Le navigateur garde les images lui-même : le dépôt par défaut suffit.
CacheInfoRepository? imageCacheRepository(String cacheKey) => null;
