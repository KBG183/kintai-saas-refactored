package com.example.kintai.architecture;

import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.domain.JavaMethod;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.lang.ArchCondition;
import com.tngtech.archunit.lang.ArchRule;
import com.tngtech.archunit.lang.ConditionEvents;
import com.tngtech.archunit.lang.SimpleConditionEvent;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.fields;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.methods;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * KINTAI アーキテクチャおよびドメイン不変条件の静的検証テスト。
 */
class KintaiArchitectureTest {

    private final JavaClasses importedClasses = new ClassFileImporter()
            .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
            .importPackages("com.example.kintai");

    @Test
    void payrollAndServiceLayersMustNotUseFloatingPointFields() {
        ArchRule rule = fields()
                .that().areDeclaredInClassesThat().resideInAnyPackage("..domain..", "..service..")
                .should().notHaveRawType(double.class)
                .andShould().notHaveRawType(Double.class)
                .andShould().notHaveRawType(float.class)
                .andShould().notHaveRawType(Float.class)
                .allowEmptyShould(true);
        rule.check(importedClasses);
    }

    @Test
    void payrollAndServiceLayersMustNotUseFloatingPointMethods() {
        ArchRule rule = methods()
                .that().areDeclaredInClassesThat().resideInAnyPackage("..domain..", "..service..")
                .should(new ArchCondition<JavaMethod>("not use double or float in return type or parameters") {
                    @Override
                    public void check(JavaMethod method, ConditionEvents events) {
                        String ret = method.getRawReturnType().getName();
                        if (isFloatingPoint(ret)) {
                            events.add(SimpleConditionEvent.violated(method,
                                    method.getFullName() + " returns floating-point type " + ret));
                        }
                        method.getRawParameterTypes().forEach(param -> {
                            String pName = param.getName();
                            if (isFloatingPoint(pName)) {
                                events.add(SimpleConditionEvent.violated(method,
                                        method.getFullName() + " accepts floating-point parameter " + pName));
                            }
                        });
                    }
                })
                .allowEmptyShould(true);
        rule.check(importedClasses);
    }

    @Test
    void controllersMustNotAccessMappersDirectly() {
        ArchRule rule = noClasses()
                .that().resideInAPackage("..controller..")
                .should().dependOnClassesThat().resideInAPackage("..mapper..")
                .allowEmptyShould(true);
        rule.check(importedClasses);
    }

    @Test
    void mappersMustBeInterfaces() {
        ArchRule rule = classes()
                .that().resideInAPackage("..mapper..")
                .should().beInterfaces()
                .allowEmptyShould(true);
        rule.check(importedClasses);
    }

    @Test
    void mybatisMappersMustNotUseDollarSignInterpolation() throws IOException {
        List<String> violations = new ArrayList<>();
        Pattern unsafeInterpolation = Pattern.compile("\\$\\{");

        Path resourcesDir = Paths.get("src/main/resources");
        if (Files.exists(resourcesDir)) {
            try (Stream<Path> paths = Files.walk(resourcesDir)) {
                paths.filter(Files::isRegularFile)
                        .filter(p -> p.toString().endsWith(".xml"))
                        .forEach(p -> scanFileForPattern(p, unsafeInterpolation, violations));
            }
        }

        Path javaDir = Paths.get("src/main/java");
        if (Files.exists(javaDir)) {
            try (Stream<Path> paths = Files.walk(javaDir)) {
                paths.filter(Files::isRegularFile)
                        .filter(p -> p.getFileName().toString().endsWith("Mapper.java"))
                        .forEach(p -> scanFileForPattern(p, unsafeInterpolation, violations));
            }
        }

        assertTrue(violations.isEmpty(),
                "Unsafe MyBatis ${} interpolation detected:\n" + String.join("\n", violations));
    }

    @Test
    void repositoryFilesMustNotContainKoreanCharacters() throws IOException {
        List<String> violations = new ArrayList<>();
        Pattern koreanPattern = Pattern.compile("[\\uAC00-\\uD7A3]");
        List<Path> targets = List.of(
                Paths.get("src"),
                Paths.get("README.md"),
                Paths.get("AGENTS.md"),
                Paths.get("GEMINI.md"),
                Paths.get(".github"),
                Paths.get("tools/prompts")
        );

        for (Path target : targets) {
            if (!Files.exists(target)) {
                continue;
            }
            try (Stream<Path> paths = Files.walk(target)) {
                paths.filter(Files::isRegularFile)
                        .filter(p -> !p.getFileName().toString().contains("_KO"))
                        .filter(KintaiArchitectureTest::isTextSourceFile)
                        .forEach(p -> scanFileForPattern(p, koreanPattern, violations));
            }
        }

        assertTrue(violations.isEmpty(),
                "Korean characters detected in tracked repository files:\n" + String.join("\n", violations));
    }

    private static void scanFileForPattern(Path path, Pattern pattern, List<String> violations) {
        try {
            List<String> lines = Files.readAllLines(path, StandardCharsets.UTF_8);
            for (int i = 0; i < lines.size(); i++) {
                Matcher matcher = pattern.matcher(lines.get(i));
                if (matcher.find()) {
                    violations.add(path + ":" + (i + 1));
                }
            }
        } catch (IOException e) {
            throw new IllegalStateException("Failed to read file: " + path, e);
        }
    }

    private static boolean isTextSourceFile(Path path) {
        String name = path.getFileName().toString().toLowerCase();
        return name.endsWith(".java")
                || name.endsWith(".xml")
                || name.endsWith(".sql")
                || name.endsWith(".properties")
                || name.endsWith(".yml")
                || name.endsWith(".yaml")
                || name.endsWith(".md")
                || name.endsWith(".ps1")
                || name.endsWith(".txt")
                || name.endsWith(".html")
                || name.endsWith(".js")
                || name.endsWith(".css");
    }

    private static boolean isFloatingPoint(String typeName) {
        return "double".equals(typeName)
                || "java.lang.Double".equals(typeName)
                || "float".equals(typeName)
                || "java.lang.Float".equals(typeName);
    }
}
