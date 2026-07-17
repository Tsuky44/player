import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';

class RequestCastList extends StatelessWidget {
  final List<RequestCastMember> cast;

  const RequestCastList({super.key, required this.cast});

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 160,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cast.length.clamp(0, 25),
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final member = cast[index];
          return SizedBox(
            width: 90,
            child: Column(
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 70,
                    height: 70,
                    child: member.profileUrl != null &&
                            member.profileUrl!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: member.profileUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => const ColoredBox(
                                color: AppColors.surfaceElevated),
                            errorWidget: (_, __, ___) => const ColoredBox(
                                color: AppColors.surfaceElevated),
                          )
                        : const ColoredBox(color: AppColors.surfaceElevated),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (member.character.isNotEmpty)
                  Text(
                    member.character,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
