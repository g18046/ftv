/// 分类与筛选模型 (home 接口返回数据)
class CategoryItem {
  final String id;
  final String name;

  CategoryItem({required this.id, required this.name});

  String get typeId => id;
  String get typeName => name;

  factory CategoryItem.fromJson(Map<String, dynamic> json) {
    return CategoryItem(
      id: json['id']?.toString() ?? json['type_id']?.toString() ?? '',
      name: json['name']?.toString() ?? json['type_name']?.toString() ?? '',
    );
  }
}

class CategoryFilterGroup {
  final String key;
  final String name;
  final List<FilterOption> options;

  CategoryFilterGroup({
    required this.key,
    required this.name,
    required this.options,
  });

  factory CategoryFilterGroup.fromJson(Map<String, dynamic> json) {
    final list = (json['value'] as List?)
            ?.map((e) => FilterOption.fromJson(Map<String, dynamic>.from(e)))
            .toList() ??
        [];
    return CategoryFilterGroup(
      key: json['key']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      options: list,
    );
  }
}

class FilterOption {
  final String name;
  final String value;

  FilterOption({required this.name, required this.value});

  factory FilterOption.fromJson(Map<String, dynamic> json) {
    return FilterOption(
      name: json['n']?.toString() ?? json['name']?.toString() ?? '',
      value: json['v']?.toString() ?? json['value']?.toString() ?? '',
    );
  }
}
