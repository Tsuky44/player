import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../../models/models.dart';
import '../../providers/library_provider.dart';
import '../../providers/auth_provider.dart';
import '../player/player_screen.dart';

class SeasonsScreen extends StatefulWidget {
  final Media show;

  const SeasonsScreen({super.key, required this.show});

  @override
  State<SeasonsScreen> createState() => _SeasonsScreenState();
}

class _SeasonsScreenState extends State<SeasonsScreen> {
  Media? _selectedSeason;
  bool _isDetecting = false;
  String? _detectionResult;

  Future<void> _detectIntroOutro() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final apiClient = authProvider.apiClient;
    setState(() {
      _isDetecting = true;
      _detectionResult = null;
    });

    try {
      final response = await http.post(
        Uri.parse('${apiClient.baseUrl}/api/debug/detect-show/${widget.show.id}'),
        headers: {
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _detectionResult = const JsonEncoder.withIndent('  ').convert(data);
        });
        // Reload episodes to show updated timestamps
        if (_selectedSeason != null) {
          final lp = Provider.of<LibraryProvider>(context, listen: false);
          await lp.loadEpisodes(_selectedSeason!.id);
        }
      } else {
        setState(() {
          _detectionResult = 'Erreur: ${response.statusCode} - ${response.body}';
        });
      }
    } catch (e) {
      setState(() {
        _detectionResult = 'Erreur: $e';
      });
    } finally {
      setState(() {
        _isDetecting = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final lp = Provider.of<LibraryProvider>(context, listen: false);
      lp.clearSeasonsAndEpisodes();
      await lp.loadSeasons(widget.show.id);

      if (lp.seasons.isNotEmpty && mounted) {
        setState(() {
          _selectedSeason = lp.seasons.first;
        });
        await lp.loadEpisodes(_selectedSeason!.id);
      }
    });
  }

  void _onSeasonChanged(Media season) async {
    setState(() {
      _selectedSeason = season;
    });
    final lp = Provider.of<LibraryProvider>(context, listen: false);
    await lp.loadEpisodes(season.id);
  }

  @override
  Widget build(BuildContext context) {
    final libraryProvider = Provider.of<LibraryProvider>(context);
    final brandColor = const Color(0xFF00A4DC);
    final hasPoster = widget.show.posterUrl != null && widget.show.posterUrl!.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        elevation: 0,
        title: Text(
          widget.show.title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (!_isDetecting)
            IconButton(
              icon: const Icon(Icons.search, color: Color(0xFF00A4DC)),
              tooltip: "Détecter Intro/Outro",
              onPressed: _detectIntroOutro,
            )
          else
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF00A4DC),
                ),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Show Header Section (Poster + Details)
            Container(
              color: const Color(0xFF1F1F1F),
              padding: const EdgeInsets.all(16.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Show Poster (Left)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 110,
                      height: 165,
                      child: hasPoster
                          ? CachedNetworkImage(
                              imageUrl: widget.show.posterUrl!,
                              fit: BoxFit.cover,
                              placeholder: (context, url) => Container(color: const Color(0xFF2B2B2B)),
                              errorWidget: (context, url, error) => Container(color: const Color(0xFF222222), child: const Icon(Icons.tv, color: Colors.grey)),
                            )
                          : Container(color: const Color(0xFF222222), child: const Icon(Icons.tv, color: Colors.grey)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  
                  // Show Details (Right)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.show.title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        if (widget.show.releaseDate != null && widget.show.releaseDate!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            "Sortie : ${widget.show.releaseDate!.split('-').first}",
                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          widget.show.overview != null && widget.show.overview!.isNotEmpty
                              ? widget.show.overview!
                              : "Aucun résumé disponible pour cette série.",
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFCCCCCC),
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Detection Results
            if (_detectionResult != null) ...[
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1F1F),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF00A4DC)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.info_outline, color: Color(0xFF00A4DC), size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          "Résultats de la détection",
                          style: TextStyle(
                            color: Color(0xFF00A4DC),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                          onPressed: () {
                            setState(() {
                              _detectionResult = null;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: SingleChildScrollView(
                        child: Text(
                          _detectionResult!,
                          style: const TextStyle(
                            color: Color(0xFFCCCCCC),
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

            // 2. Seasons horizontal chips row
            if (libraryProvider.isLoadingSeasons)
              const Center(child: CircularProgressIndicator(color: Color(0xFF00A4DC)))
            else if (libraryProvider.seasons.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  "Saisons",
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 40,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: libraryProvider.seasons.length,
                  itemBuilder: (context, index) {
                    final season = libraryProvider.seasons[index];
                    final isSelected = _selectedSeason?.id == season.id;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(season.title),
                        selected: isSelected,
                        selectedColor: brandColor,
                        backgroundColor: const Color(0xFF1F1F1F),
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.white : Colors.grey,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                        onSelected: (_) => _onSeasonChanged(season),
                      ),
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: 24),

            // 3. Episodes vertical list
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                "Épisodes",
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 10),

            if (libraryProvider.isLoadingEpisodes)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator(color: Color(0xFF00A4DC))))
            else if (libraryProvider.episodes.isNotEmpty)
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: libraryProvider.episodes.length,
                separatorBuilder: (context, index) => const Divider(color: Color(0xFF1F1F1F), height: 1),
                itemBuilder: (context, index) {
                  final episode = libraryProvider.episodes[index];
                  final isStarted = episode.currentPositionSeconds > 0 && !episode.isFinished;
                  final isFinished = episode.isFinished;

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    tileColor: const Color(0xFF1A1A1A),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.3),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isFinished
                            ? Icons.check_circle
                            : isStarted
                                ? Icons.play_arrow_outlined
                                : Icons.play_arrow,
                        color: isFinished
                            ? Colors.green
                            : isStarted
                                ? brandColor
                                : Colors.white,
                        size: 24,
                      ),
                    ),
                    title: Text(
                      episode.media.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isFinished)
                          const Text("Vu", style: TextStyle(color: Colors.green, fontSize: 12))
                        else if (isStarted)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(2),
                                    child: LinearProgressIndicator(
                                      value: episode.percentWatched,
                                      backgroundColor: Colors.grey.withOpacity(0.2),
                                      valueColor: AlwaysStoppedAnimation<Color>(brandColor),
                                      minHeight: 3,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  "${(episode.percentWatched * 100).toInt()}%",
                                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PlayerScreen(media: episode),
                        ),
                      );
                    },
                  );
                },
              )
            else
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Text(
                    "Aucun épisode indexé pour cette saison",
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
