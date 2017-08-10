import 'dart:async';

import 'package:analyzer/dart/ast/ast.dart' as ast;
import 'package:analyzer/dart/element/element.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:source_gen/source_gen.dart';

import 'di/dependencies.dart';
import 'types.dart';

/// Determines how to generate and link to `initReflector` in other files.
///
/// AngularDart's `initReflector` is used to create a graph of all generated
/// code that mirrors user-authored code. Significant classes and factories are
/// recorded into a global map and can be used at runtime (via the `reflector`).
///
/// The recorder has various options on how much recording is required for a
/// given application, with the end-goal being requiring little or none for most
/// applications.
class ReflectableReader {
  static const _defaultOutputExtension = '.template.dart';

  /// Used to read dependencies from dart objects.
  final DependencyReader dependencyReader;

  /// Returns whether [uri] is a file part of the same build process.
  ///
  /// Used to determine whether [uri] (i.e. `foo.dart`) _will_ generate a future
  /// output (i.e. `foo.template.dart`). It should be assumed the [uri]
  /// parameter, if a relative URI, is relative to the library being analyzed.
  final FutureOr<bool> Function(String uri) hasInput;

  /// Returns whether [uri] represents a summarized/analyzed dart library.
  ///
  /// It should be assumed the [uri] parameter, if a relative URI, is relative
  /// to the library being analyzed.
  final bool Function(String uri) isLibrary;

  /// File extension used when compiling AngularDart files.
  ///
  /// By default this is `.template.dart`.
  final String outputExtension;

  /// Whether to treat an `@Component`-annotated `class` as an `@Component`.
  ///
  /// This means that a factory to create the component at runtime needs to be
  /// registered. This also disables tree-shaking classes annotated with
  /// `@Component`.
  final bool recordComponentsAsInjectables;

  /// Whether to treat an `@Directive`-annotated `class` as an `@Injectable`.
  ///
  /// This means that a factory to create the directive at runtime needs to be
  /// registered. This also disables tree-shaking classes annotated with
  /// `@Directive`.
  final bool recordDirectivesAsInjectables;

  /// Whether to treat a `@Pipe`-annotated `class` as an `@Injectable`.
  ///
  /// This means that a factory to create the pipe at runtime needs to be
  /// registered. This also disables tree-shaking classes annotated with
  /// `@Pipe`.
  final bool recordPipesAsInjectables;

  /// Whether to record `@RouteConfig`s for `@Component`-annotated classes.
  ///
  /// This is only required in order to support the legacy router, which looks
  /// up metadata information at runtime in order to configure itself.
  final bool recordRouterAnnotationsForComponents;

  const ReflectableReader({
    this.dependencyReader: const DependencyReader(),
    @required this.hasInput,
    @required this.isLibrary,
    this.outputExtension: _defaultOutputExtension,
    this.recordComponentsAsInjectables: true,
    this.recordDirectivesAsInjectables: true,
    this.recordPipesAsInjectables: true,
    this.recordRouterAnnotationsForComponents: true,
  });

  /// Always emits an empty [ReflectableOutput.urlsNeedingInitReflector].
  ///
  /// Useful for tests that do not want to try emulating a complete build.
  @visibleForTesting
  const ReflectableReader.noLinking({
    this.dependencyReader: const DependencyReader(),
    this.outputExtension: _defaultOutputExtension,
    this.recordComponentsAsInjectables: true,
    this.recordDirectivesAsInjectables: true,
    this.recordPipesAsInjectables: true,
    this.recordRouterAnnotationsForComponents: true,
  })
      : hasInput = _nullHasInput,
        isLibrary = _nullIsLibrary;

  static FutureOr<bool> _nullHasInput(_) => false;
  static bool _nullIsLibrary(_) => false;

  /// Returns information needed to write `.template.dart` files.
  Future<ReflectableOutput> resolve(LibraryElement library) async {
    final unit = library.definingCompilationUnit;
    final registerClasses = <ReflectableClass>[];
    for (final type in unit.types) {
      final reflectable = _resolveClass(type);
      if (reflectable != null) {
        registerClasses.add(reflectable);
      }
    }
    final registerFunctions = unit.functions
        .where((e) => $Injectable.firstAnnotationOfExact(e) != null)
        .map(dependencyReader.parseDependencies)
        .toList();
    return new ReflectableOutput(
      urlsNeedingInitReflector: await _resolveNeedsReflector(library),
      registerClasses: registerClasses,
      registerFunctions: registerFunctions,
    );
  }

  ReflectableClass _resolveClass(ClassElement element) {
    DependencyInvocation<ConstructorElement> factory;
    if (_shouldRecordFactory(element)) {
      factory = dependencyReader.parseDependencies(element);
    }
    final isComponent = $Component.firstAnnotationOfExact(element) != null;
    if (factory == null && !isComponent) {
      return null;
    }
    return new ReflectableClass(
      factory: factory,
      name: element.name,
      registerAnnotation: recordRouterAnnotationsForComponents && isComponent
          ? _findRouteConfig(element)?.revive()
          : null,
      registerComponentFactory: isComponent,
    );
  }

  // We don't use a TypeChecker because this is in another library, and would
  // complicate things. Since this is only a single annotation that is rarely
  // used (and will be removed), it's not a big deal.
  ConstantReader _findRouteConfig(ClassElement element) {
    for (final annotation in element.metadata) {
      final object = annotation.computeConstantValue();
      if (object?.type?.name == 'RouteConfig') {
        return new ConstantReader(object);
      }
    }
    return null;
  }

  String _withOutputExtension(String uri) {
    final extensionAt = uri.lastIndexOf('.');
    return uri.substring(0, extensionAt) + outputExtension;
  }

  Future<List<String>> _resolveNeedsReflector(LibraryElement library) async {
    final directives = library.definingCompilationUnit.computeNode().directives;
    final results = <String>[];
    await Future.wait(directives.map((d) async {
      if (await _needsInitReflector(d)) {
        var uri = (d as ast.UriBasedDirective).uri.stringValue;
        // Always link to the .template.dart file equivalent of a file.
        if (!uri.endsWith(outputExtension)) {
          uri = _withOutputExtension(uri);
        }
        results.add(uri);
      }
    }));
    return results..sort();
  }

  // Determines whether initReflector needs to link to [directive].
  Future<bool> _needsInitReflector(ast.Directive directive) async {
    if (directive is ast.ImportDirective) {
      // Do not link to deferred code.
      if (directive.deferredKeyword != null) {
        return false;
      }
      // Always link when manually importing .template.dart files.
      final uri = directive.uri.stringValue;
      if (uri.endsWith(outputExtension)) {
        return true;
      }
    }
    // Link if we are have or will have a .template.dart file.
    if (directive is ast.UriBasedDirective) {
      final uri = directive.uri.stringValue;
      if (uri.startsWith('dart:')) {
        return false;
      }
      final outputUri = _withOutputExtension(uri);
      return isLibrary(outputUri) || await hasInput(uri);
    }
    return false;
  }

  bool _shouldRecordFactory(ClassElement element) =>
      $Injectable.firstAnnotationOfExact(element) != null ||
      recordComponentsAsInjectables &&
          $Component.firstAnnotationOfExact(element) != null ||
      recordDirectivesAsInjectables &&
          $Directive.firstAnnotationOfExact(element) != null ||
      recordPipesAsInjectables && $Pipe.firstAnnotationOfExact(element) != null;
}

class ReflectableOutput {
  /// What `.template.dart` files need to be imported and linked to this file.
  final List<String> urlsNeedingInitReflector;

  /// What `class` elements require registration in `initReflector`.
  final List<ReflectableClass> registerClasses;

  /// What factory functions require registration in `initReflector`.
  final List<DependencyInvocation<FunctionElement>> registerFunctions;

  @visibleForTesting
  const ReflectableOutput({
    this.urlsNeedingInitReflector: const [],
    this.registerClasses: const [],
    this.registerFunctions: const [],
  });

  static const _list = const ListEquality<Object>();

  @override
  bool operator ==(Object o) =>
      o is ReflectableOutput &&
      _list.equals(urlsNeedingInitReflector, o.urlsNeedingInitReflector) &&
      _list.equals(registerClasses, o.registerClasses) &&
      _list.equals(registerFunctions, o.registerFunctions);

  @override
  int get hashCode =>
      _list.hash(urlsNeedingInitReflector) ^
      _list.hash(registerClasses) ^
      _list.hash(registerFunctions);

  @override
  String toString() =>
      'ReflectableOutput ' +
      {
        'urlsNeedingInitReflector': urlsNeedingInitReflector,
        'registerClasses': registerClasses,
        'registerFunctions': registerFunctions,
      }.toString();
}

class ReflectableClass {
  /// Factory required to invoke the constructor of the class.
  final DependencyInvocation<ConstructorElement> factory;

  /// Name of the class.
  final String name;

  /// If non-null, this object should be registered as an annotation.
  final Revivable registerAnnotation;

  /// If `true`, this class has an `NgFactory` needing registration.
  final bool registerComponentFactory;

  @visibleForTesting
  const ReflectableClass({
    this.factory,
    @required this.name,
    this.registerAnnotation,
    this.registerComponentFactory: false,
  });

  @override
  bool operator ==(Object o) =>
      o is ReflectableClass &&
      factory == o.factory &&
      name == o.name &&
      registerAnnotation?.source == o.registerAnnotation?.source &&
      registerComponentFactory == o.registerComponentFactory;

  @override
  int get hashCode =>
      factory.hashCode ^
      name.hashCode ^
      (registerAnnotation?.source?.hashCode ?? 0) ^
      registerComponentFactory.hashCode;

  @override
  String toString() =>
      'ReflectableClass' +
      {
        'factory': factory,
        'name': name,
        'registerAnnotation': '${registerAnnotation?.source}',
        'registerComponentFactory': registerComponentFactory,
      }.toString();
}