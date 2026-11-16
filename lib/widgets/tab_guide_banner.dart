import 'package:flutter/material.dart';

/// Một nhóm nội dung trong khung hướng dẫn của từng tab.
class TabGuideSection {
  const TabGuideSection({
    required this.heading,
    required this.steps,
  });

  final String heading;
  final List<String> steps;
}

/// Khung hướng dẫn cài đặt & sử dụng thu gọn được, tái sử dụng đồng nhất cho cả 5 tab.
class TabGuideBanner extends StatefulWidget {
  const TabGuideBanner({
    super.key,
    required this.title,
    required this.sections,
    this.accentColor = Colors.blue,
    this.highlightNote,
    this.margin = const EdgeInsets.fromLTRB(16, 4, 16, 8),
    this.initiallyExpanded = false,
    this.maxExpandedHeight,
  });

  final String title;
  final List<TabGuideSection> sections;
  final MaterialColor accentColor;
  final String? highlightNote;
  final EdgeInsetsGeometry margin;
  final bool initiallyExpanded;
  final double? maxExpandedHeight;

  @override
  State<TabGuideBanner> createState() => _TabGuideBannerState();
}

class _TabGuideBannerState extends State<TabGuideBanner> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor;
    return Container(
      margin: widget.margin,
      decoration: BoxDecoration(
        color: accent.shade50.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.menu_book_outlined,
                    size: 17,
                    color: accent.shade800,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: accent.shade900,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: accent.shade100,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _expanded ? 'Thu gọn' : 'Xem hướng dẫn',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: accent.shade900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: accent.shade800,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Builder(
              builder: (context) {
                final details = Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Divider(height: 12, color: accent.shade200),
                      for (var s = 0; s < widget.sections.length; s++) ...[
                        if (s > 0) const SizedBox(height: 8),
                        Text(
                          widget.sections[s].heading,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: accent.shade900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        for (var i = 0; i < widget.sections[s].steps.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${i + 1}. ',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: accent.shade800,
                                    height: 1.35,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    widget.sections[s].steps[i],
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.grey.shade900,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      if (widget.highlightNote != null &&
                          widget.highlightNote!.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: accent.shade200),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.tips_and_updates_outlined,
                                size: 14,
                                color: accent.shade800,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  widget.highlightNote!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: accent.shade900,
                                    fontWeight: FontWeight.w500,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                );
                if (widget.maxExpandedHeight != null) {
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: widget.maxExpandedHeight!),
                    child: SingleChildScrollView(child: details),
                  );
                }
                return details;
              },
            ),
        ],
      ),
    );
  }
}
