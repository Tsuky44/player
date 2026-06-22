import 'dart:async';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_client.dart';

class HomeProvider extends ChangeNotifier {
  final ApiClient apiClient;

  HomeResponse? _homeData;
  bool _isLoading = false;
  bool _isScanning = false;
  String? _errorMessage;
  Timer? _scanPollTimer;

  HomeProvider(this.apiClient);

  HomeResponse? get homeData => _homeData;
  bool get isLoading => _isLoading;
  bool get isScanning => _isScanning;
  String? get errorMessage => _errorMessage;

  @override
  void dispose() {
    _scanPollTimer?.cancel();
    super.dispose();
  }

  // Load dashboard data
  Future<void> loadHome({bool silent = false}) async {
    if (!silent) {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      _homeData = await apiClient.getHome();
      _errorMessage = null;
      
      // Also fetch indexer status once silently
      _isScanning = await apiClient.getScanStatus();
      if (_isScanning) {
        _startScanPolling();
      }
    } catch (e) {
      _errorMessage = "Impossible de charger la page d'accueil : ${e.toString()}";
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Trigger library scan
  Future<void> triggerLibraryScan() async {
    if (_isScanning) return;

    try {
      await apiClient.triggerScan();
      _isScanning = true;
      notifyListeners();
      _startScanPolling();
    } catch (e) {
      _errorMessage = "Erreur lors du lancement du scan : ${e.toString()}";
      notifyListeners();
    }
  }

  // Poll server for scan status
  void _startScanPolling() {
    _scanPollTimer?.cancel();
    _scanPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final scanning = await apiClient.getScanStatus();
        if (!scanning) {
          // Scan finished!
          _isScanning = false;
          timer.cancel();
          notifyListeners();
          
          // Auto reload home data silently to reflect new media
          await loadHome(silent: true);
        }
      } catch (_) {
        // If query fails, stop polling to avoid loops
        _isScanning = false;
        timer.cancel();
        notifyListeners();
      }
    });
  }
}
