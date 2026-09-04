import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/offline_queue.dart';

/// Screen 3 — Catalog Preview.
///
/// Fetches the AI-processed catalog entry for a given [catalogId] from the
/// backend (cleaned image, EN/HI titles, transcript, calculated price) and
/// lets the artisan approve it for publishing to the ONDC network.
class CatalogPreviewScreen extends StatefulWidget {
  const CatalogPreviewScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  State<CatalogPreviewScreen> createState() => _CatalogPreviewScreenState();
}

class _CatalogPreviewScreenState extends State<CatalogPreviewScreen> {
  Map<String, dynamic>? _catalog;
  bool _loading = true;
  bool _publishing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // In production, the artisan_id would come from an auth/session
      // provider. Passed here for illustration — see main.dart for how
      // it's threaded through from login/onboarding.
      final uri = Uri.parse(
        '$kBackendBaseUrl/api/v1/catalogs/${Uri.encodeComponent(widget.catalogId)}',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _catalog = list.isNotEmpty ? list.first as Map<String, dynamic> : null;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Server error ${response.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _approveAndPublish() async {
    setState(() => _publishing = true);
    try {
      final uri = Uri.parse('$kBackendBaseUrl/api/v1/ondc/publish');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'catalog_id': widget.catalogId}),
      );
      if (response.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Published to ONDC!')),
        );
        Navigator.of(context).pop();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Publish failed: ${response.statusCode}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Catalog Preview')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : _catalog == null
                  ? const Center(child: Text('Catalog not found'))
                  : _buildContent(_catalog!),
    );
  }

  Widget _buildContent(Map<String, dynamic> c) {
    final imageUrl = c['cleaned_image_path'] as String?;
    final bulletPoints = (c['description_bullet_points'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                imageUrl,
                height: 260,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 260,
                  color: Colors.grey.shade200,
                  child: const Icon(Icons.image, size: 64, color: Colors.grey),
                ),
              ),
            ),
          const SizedBox(height: 16),

          Text(c['title_en'] ?? '', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text(c['title_hi'] ?? '', style: const TextStyle(fontSize: 18, color: Colors.black54)),
          const SizedBox(height: 8),
          Chip(label: Text(c['category'] ?? 'Uncategorized')),

          const SizedBox(height: 16),
          const Text('Description', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          ...bulletPoints.map((b) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(b)),
                  ],
                ),
              )),

          const SizedBox(height: 16),
          const Text('Voice Transcript', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          Text(c['transcript'] ?? '', style: const TextStyle(fontStyle: FontStyle.italic)),

          const SizedBox(height: 20),
          Card(
            color: const Color(0xFFE8F5E9),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Suggested Price', style: TextStyle(fontSize: 16)),
                  Text(
                    '₹${(c['suggested_price'] as num?)?.toStringAsFixed(0) ?? '-'}',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF2E7D32)),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: _publishing ? null : _approveAndPublish,
              child: _publishing
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text('Approve & Push to ONDC', style: TextStyle(fontSize: 18)),
            ),
          ),
        ],
      ),
    );
  }
}
