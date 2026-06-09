import 'package:flutter/material.dart';

// GIPHY API key. Paste your key here.
// Get key from: https://developers.giphy.com/dashboard/
const String kGiphyApiKey = 'i81oKIGsVa1IIT3k2wYkykFk2CpKSnau';

bool get isGiphyConfigured =>
    kGiphyApiKey.isNotEmpty && kGiphyApiKey != 'PASTE_YOUR_GIPHY_API_KEY_HERE';

const Color kAccentCyan = Color(0xFF00E5FF);
const Color kBgBlack = Color(0xFF000000);
const Color kBgSurface = Color(0xFF1A1A1A);
const Color kBgSurface2 = Color(0xFF2A2A2A);
const Color kTextSecondary = Color(0xFFAAAAAA);

const List<int> kResolutionPresets = [480, 540, 720, 1080, 2160];
const List<int> kFramerates = [24, 25, 30, 50, 60];
const List<int> kBitratePresets = [5, 10, 20, 50, 100];
