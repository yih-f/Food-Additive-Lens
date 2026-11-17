//
//  ContentView.swift
//  foodadditiveparser
//
//  Created by Yihang Feng on 6/26/25.
//

import SwiftUI
import CoreData
import MLX
import MLXRandom
import MLXLLM
import MLXLMCommon
import Foundation
import CoreML
import NaturalLanguage
import Accelerate
import Vision
import UIKit

// MARK: - ContentView
struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var identifier = MLXAdditiveIdentifier()
    @State private var knowledgeManager = AdditiveKnowledgeManager()
    @State private var cfrManager = CFRManager()
    @State private var ingredientText = ""
    @State private var identifiedAdditives: [String]?
    @State private var additiveKnowledge: [AdditiveKnowledgeManager.AdditiveKnowledge]?
    @State private var showingResults = false
    @State private var showingHistory = false
    @State private var showingSaveSuccess = false
    @State private var availableIngredients: [String] = []
    @State private var availableFoodRecords: [FoodRecord] = []
    @State private var currentFoodRecord: FoodRecord? = nil
    @State private var isLoadingIngredients = false
    @State private var selectedEntryId: String = ""
    @State private var showingEntryId: Int? = nil
    @State private var entryIdError: String? = nil
    @State private var additiveExplanations: String = ""
    @State private var isGeneratingExplanations = false
    @State private var isLookingUpKnowledge = false
    @State private var llmStage: String = ""
    @State private var showingImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .camera
    @State private var selectedImage: UIImage?
    @State private var isProcessingOCR = false
    @State private var showingCameraPicker = false
    @State private var showingPhotoPicker = false
    @State private var foodClassifier = FoodCategoryClassifier()
    @State private var classificationResults: [ClassificationResult] = []
    @State private var isClassifying = false
    @State private var selectedFoodCategory: String? = nil
    @State private var showingCategorySelection = false
    @State private var showingAboutSheet = false
    @FocusState private var isTextEditorFocused: Bool
    @FocusState private var isEntryIdFocused: Bool
    @State private var showingUnsupportedDeviceAlert = false
    @State private var deviceModel = ""
    let sampleIngredient = """
    ENRICHED WHEAT FLOUR (FLOUR, NIACIN, REDUCED IRON, THIAMINE MONONITRATE, RIBOFLAVIN, FOLIC ACID), WATER, SUGAR, SOYBEAN OIL, YEAST, SALT, CALCIUM PROPIONATE (PRESERVATIVE), MONOGLYCERIDES, SODIUM STEAROYL LACTYLATE, CALCIUM SULFATE, ENZYMES, ASCORBIC ACID
    """
    var body: some View {
        NavigationView {
            ZStack {
                // Gradient background that works in both light and dark mode
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "#F5F7FA"),
                        Color(hex: "#E9ECEF")
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                                    VStack(spacing: 24) {
                                        headerView
                                        modelStatusView
                                        inputSection
                                        
                                        // Show food record info only for sampled entries
                                        if let _ = currentFoodRecord {
                                            foodRecordInfoSection
                                        }
                                        
                                        buttonSection
                                        
                                        if let knowledge = additiveKnowledge {
                                            knowledgeSection(knowledge)
                                        }
                                    }
                                    .padding()
                                }
                                .onAppear {
                                    // Load CSV data first, then other models
                                    if availableIngredients.isEmpty && !isLoadingIngredients {
                                        loadIngredientsFromCSV()
                                    }
                                }
            }
            .navigationTitle("Food Additive Lens")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingHistory = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16, weight: .medium))
                            Text("History")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(20)
                    }
                }
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView()
                    .environment(\.managedObjectContext, viewContext)
            }
            .sheet(isPresented: $showingImagePicker) {
                ImagePicker(image: $selectedImage, sourceType: imagePickerSourceType)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let image = selectedImage {
                            processImageWithOCR(image)
                            selectedImage = nil
                        }
                    }
                    .interactiveDismissDisabled(isProcessingOCR)
            }
            .sheet(isPresented: $showingCameraPicker) {
                ImagePicker(image: $selectedImage, sourceType: .camera)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let image = selectedImage {
                            processImageWithOCR(image)
                            selectedImage = nil
                        }
                    }
            }
            .sheet(isPresented: $showingPhotoPicker) {
                ImagePicker(image: $selectedImage, sourceType: .photoLibrary)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let image = selectedImage {
                            processImageWithOCR(image)
                            selectedImage = nil
                        }
                    }
            }
            .sheet(isPresented: $showingAboutSheet) {
                AboutView()
            }
            .alert("Success", isPresented: $showingSaveSuccess) {
                Button("OK") { }
            } message: {
                Text("Successfully saved to history!")
            }
            .alert("Feature Not Available", isPresented: $showingUnsupportedDeviceAlert) {
                Button("OK") { }
            } message: {
                if UIDevice.isRunningOnMac() {
                    Text("The AI analysis feature is not supported on this Mac configuration. Please try on a supported iPhone (iPhone 14 or newer) or a newer Mac.")
                } else {
                    Text("The AI analysis feature requires iPhone 14 or newer. Your device (\(deviceModel)) is not currently supported.")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isTextEditorFocused = false
                isEntryIdFocused = false
            }
        }
        .preferredColorScheme(.light) // Force light mode to avoid black background
    }
    private func loadIngredientsFromCSV() {
        isLoadingIngredients = true
        
        Task(priority: .userInitiated) {
            do {
                guard let path = Bundle.main.path(forResource: "branded_food_short_sample", ofType: "csv") else {
                    print("❌ CSV file not found in bundle")
                    await MainActor.run {
                        self.isLoadingIngredients = false
                    }
                    return
                }
                
                let content = try String(contentsOfFile: path)
                let lines = content.components(separatedBy: .newlines)
                
                var ingredients: [String] = []
                var foodRecords: [FoodRecord] = []
                
                // Skip header (first line) and process remaining lines
                for line in lines.dropFirst() {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    
                    let columns = parseCSVLine(line)
                    // Check if we have enough columns
                    if columns.count >= 7 {
                        let fdcId = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let brandOwner = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        let brandName = columns[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        let subBrandName = columns[3].trimmingCharacters(in: .whitespacesAndNewlines)
                        let ingredientText = columns[4].trimmingCharacters(in: .whitespacesAndNewlines)
                        let brandedFoodCategory = columns[5].trimmingCharacters(in: .whitespacesAndNewlines)
                        let description = columns[6].trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Only include records with required fields and good ingredient length
                        if !brandOwner.isEmpty &&
                           !brandedFoodCategory.isEmpty &&
                           !ingredientText.isEmpty &&
                           ingredientText.count > 50 &&
                           ingredientText.contains(",") {
                            
                            let foodRecord = FoodRecord(
                                fdcId: fdcId,
                                brandOwner: brandOwner,
                                brandName: brandName,
                                subBrandName: subBrandName,
                                ingredients: ingredientText,
                                brandedFoodCategory: brandedFoodCategory,
                                description: description
                            )
                            foodRecords.append(foodRecord)
                            ingredients.append(ingredientText)
                        }
                    }
                }
                
                await MainActor.run {
                    self.availableIngredients = ingredients
                    self.availableFoodRecords = foodRecords
                    self.isLoadingIngredients = false
                    print("✅ Loaded \(foodRecords.count) food records from CSV")
                }
                
            } catch {
                print("❌ Failed to load CSV: \(error)")
                await MainActor.run {
                    self.isLoadingIngredients = false
                }
            }
        }
    }
    private func parseCSVLine(_ line: String) -> [String] {
        var columns: [String] = []
        var currentColumn = ""
        var insideQuotes = false
        var i = line.startIndex
        
        while i < line.endIndex {
            let char = line[i]
            
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == "," && !insideQuotes {
                columns.append(currentColumn)
                currentColumn = ""
            } else {
                currentColumn.append(char)
            }
            
            i = line.index(after: i)
        }
        
        // Add the last column
        columns.append(currentColumn)
        
        // Clean up quotes from columns
        return columns.map { column in
            var cleaned = column.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
                cleaned = String(cleaned.dropFirst().dropLast())
            }
            return cleaned
        }
    }
    private var headerView: some View {
        VStack(spacing: 12) {
            // Icon with gradient background
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue, Color.purple]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 5)
                
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
            
            // 🆕 IMPROVED: Enhanced feature showcase
            VStack(spacing: 8) {
                Text("AI-Powered Analysis")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                // 🆕 NEW: Three-feature horizontal layout with icons
                HStack(spacing: 16) {
                    // Feature 1: Smart Identification
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 32, height: 32)
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.blue)
                        }
                        Text("Smart\nIdentification")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    
                    // Connector
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Feature 2: Knowledge Lookup
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.15))
                                .frame(width: 32, height: 32)
                            Image(systemName: "book.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.orange)
                        }
                        Text("Knowledge\nLookup")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    
                    // Connector
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Feature 3: AI Explanation
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.15))
                                .frame(width: 32, height: 32)
                            Image(systemName: "text.bubble.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.purple)
                        }
                        Text("AI\nExplanation")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.purple)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 8)
            }
            
            // How it works button
            Button(action: { showingAboutSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                    Text("How It Works?")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(15)
            }
            .padding(.top, 4)
        }
        .padding(.vertical)
    }
    private func loadRandomSample() {
        guard !availableFoodRecords.isEmpty else {
            ingredientText = sampleIngredient
            showingEntryId = -1
            currentFoodRecord = nil
            return
        }
        
        // Filter for longer entries (prefer entries with more ingredients)
        let longerEntries = availableFoodRecords.filter { $0.ingredients.count > 100 }
        let entriesToUse = longerEntries.isEmpty ? availableFoodRecords : longerEntries
        
        let randomIndex = Int.random(in: 0..<entriesToUse.count)
        let selectedRecord = entriesToUse[randomIndex]
        
        // Find the actual index in the full array
        let actualIndex = availableFoodRecords.firstIndex { $0.fdcId == selectedRecord.fdcId } ?? randomIndex
        
        ingredientText = selectedRecord.ingredients
        currentFoodRecord = selectedRecord
        showingEntryId = actualIndex
        isTextEditorFocused = false
        entryIdError = nil
        
        print("📝 Random sample: Entry ID \(actualIndex), \(selectedRecord.ingredients.count) characters")
    }
    private func loadSpecificEntry() {
        guard let entryId = Int(selectedEntryId.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            entryIdError = "Invalid ID format"
            return
        }
        
        guard entryId >= 0 && entryId < availableFoodRecords.count else {
            entryIdError = "ID out of range (0-\(availableFoodRecords.count - 1))"
            return
        }
        
        let selectedRecord = availableFoodRecords[entryId]
        ingredientText = selectedRecord.ingredients
        currentFoodRecord = selectedRecord
        showingEntryId = entryId
        entryIdError = nil
        isTextEditorFocused = false
        isEntryIdFocused = false
        selectedEntryId = ""
        
        print("📝 Loaded specific entry: ID \(entryId), \(selectedRecord.ingredients.count) characters")
    }
    private func formatChemicalName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If it's all uppercase, convert to title case
        if trimmed == trimmed.uppercased() {
            return trimmed.capitalized
        }
        
        // If it's already properly formatted, return as-is
        return trimmed
    }
    private func formatTechnicalEffect(_ effect: String) -> String {
        // Split by "|" and clean up
        let effects = effect.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        // Format each effect (convert from all caps if needed)
        let formattedEffects = effects.map { singleEffect in
            if singleEffect == singleEffect.uppercased() {
                return singleEffect.capitalized
            }
            return singleEffect
        }
        
        // Join with commas and "and" for the last item if multiple effects
        if formattedEffects.count <= 1 {
            return formattedEffects.first ?? ""
        } else if formattedEffects.count == 2 {
            return formattedEffects.joined(separator: " and ")
        } else {
            let allButLast = formattedEffects.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(formattedEffects.last!)"
        }
    }
    private func formatOtherNames(_ otherNames: String, originalName: String) -> String {
        // Split by "|" and clean up
        let names = otherNames.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.lowercased() != originalName.lowercased() } // Remove original name
        
        // Format each name (convert from all caps if needed)
        let formattedNames = names.map { name in
            if name == name.uppercased() {
                return name.capitalized
            }
            return name
        }
        
        // Join with commas instead of "|"
        return formattedNames.joined(separator: ", ")
    }
    private var modelStatusView: some View {
        VStack(spacing: 12) {
            if identifier.isModelLoaded && knowledgeManager.isReady && foodClassifier.isLoaded && cfrManager.isLoaded {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                    
                    Text("All Systems Ready")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                    
                    Spacer()
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(12)
            } else {
                // Prominent loading banner
                VStack(spacing: 16) {
                    HStack {
                        ProgressView()
                            .scaleEffect(1.2)
                            .frame(width: 30, height: 30)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Loading AI Models...")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                            
                            Text("Please wait while we initialize the app")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                    
                    // Detailed status
                    VStack(spacing: 8) {
                        statusRow(
                            title: "LLM Model",
                            isReady: identifier.isModelLoaded,
                            isLoading: identifier.isLoading,
                            detail: identifier.modelInfo
                        )
                        
                        statusRow(
                            title: "Knowledge Base",
                            isReady: knowledgeManager.isReady,
                            isLoading: knowledgeManager.isLoading,
                            detail: "Food additive database"
                        )
                        
                        statusRow(
                            title: "Food Classifier",
                            isReady: foodClassifier.isLoaded,
                            isLoading: foodClassifier.isLoading,
                            detail: "Category prediction model"
                        )
                        
                        statusRow(
                            title: "CFR Database",
                            isReady: cfrManager.isLoaded,
                            isLoading: cfrManager.isLoading,
                            detail: "Federal regulations database"
                        )
                    }
                    .padding()
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                }
            }
        }
    }

    private func statusRow(title: String, isReady: Bool, isLoading: Bool, detail: String) -> some View {
        HStack {
            ZStack {
                Circle()
                    .fill(isReady ? Color.green : (isLoading ? Color.orange : Color.gray))
                    .frame(width: 16, height: 16)
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 20, height: 20)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isLoading {
                ProgressView()
                    .scaleEffect(0.9)
            } else if isReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            }
        }
    }
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                        actionButton(
                            title: "Reset",
                            icon: "arrow.counterclockwise",
                            color: .purple,
                            action: resetAppContent,
                            disabled: !canReset
                        )
                        
                        Menu {
                            Button(action: { showingCameraPicker = true }) {
                                Label("Take Photo", systemImage: "camera")
                            }
                            
                            Button(action: { showingPhotoPicker = true }) {
                                Label("Choose Photo", systemImage: "photo")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "text.viewfinder")
                                Text(isProcessingOCR ? "Processing..." : "Scan Ingredients")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(minWidth: 90)
                            .background(isProcessingOCR ? Color.gray : Color.orange)
                            .cornerRadius(20)
                        }
                        .disabled(isProcessingOCR)
                
                Spacer()
            }
            
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(.blue)
                Text("Ingredient List")
                    .font(.headline)
                
                Spacer()
                
                // 🆕 MOVED: Random Sample button to the right of title
                Button(action: loadRandomSample) {
                    HStack(spacing: 6) {
                        Image(systemName: "dice")
                            .font(.caption)
                        Text(isLoadingIngredients ? "Loading..." : "Random Sample")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isLoadingIngredients ? Color.gray : Color.blue)
                    .cornerRadius(20)
                }
                .disabled(isLoadingIngredients)
            }
            
            // Text Editor section (unchanged)
            ScrollView {
                TextEditor(text: $ingredientText)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(12)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isTextEditorFocused ? Color.blue : Color.clear, lineWidth: 2)
                    )
                    .focused($isTextEditorFocused)
            }
            .frame(maxHeight: 200)
        }
    }
    private var foodRecordInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                Text("Sample Food Product")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 8) {
                // Product name and brand
                HStack(alignment: .top) {
                    Text("Product:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        if !currentFoodRecord!.description.isEmpty {
                            Text(currentFoodRecord!.description)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        Text("by \(currentFoodRecord!.brandOwner)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                
                // Category
                if !currentFoodRecord!.brandedFoodCategory.isEmpty {
                    HStack(alignment: .top) {
                        Text("Category:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(currentFoodRecord!.brandedFoodCategory)
                            .font(.caption)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
                
                // Brand names if available
                if !currentFoodRecord!.brandName.isEmpty || !currentFoodRecord!.subBrandName.isEmpty {
                    HStack(alignment: .top) {
                        Text("Brand:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 1) {
                            if !currentFoodRecord!.brandName.isEmpty {
                                Text(currentFoodRecord!.brandName)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            if !currentFoodRecord!.subBrandName.isEmpty {
                                Text(currentFoodRecord!.subBrandName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                
                // Entry ID
                if let entryId = showingEntryId, entryId >= 0 {
                    HStack(alignment: .top) {
                        Text("Entry ID:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text("\(entryId)")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .fontWeight(.medium)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }
    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(minWidth: 100)
            .background(disabled ? Color.gray : color)
            .cornerRadius(20)
        }
        .disabled(disabled)
    }
    private var buttonSection: some View {
        VStack(spacing: 16) {
            categoryClassificationSection
            additiveIdentificationSection
        }
    }

    private var categoryClassificationSection: some View {
        VStack(spacing: 16) {
            // Food Category Classification Button
            Button(action: classifyFoodCategory) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.2))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: "tag.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 20))
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Classify Food Category")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text(isClassifying ? "Analyzing ingredients..." : "Identify what type of food this is")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if isClassifying {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .padding()
                .background(Color.white)
                .cornerRadius(16)
                .shadow(color: canClassifyCategory ? Color.orange.opacity(0.2) : Color.gray.opacity(0.1),
                       radius: 8, x: 0, y: 4)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canClassifyCategory)
            .opacity(canClassifyCategory ? 1 : 0.6)
            
            // Classification Results
            if !classificationResults.isEmpty {
                classificationResultsSection
            }
        }
    }

    private var classificationResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            classificationHeader
            classificationResultsList
            if selectedFoodCategory != nil {
                classificationBottomInfo
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    private var classificationHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Food Category Predictions")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            if selectedFoodCategory == nil {
                HStack {
                    Image(systemName: "hand.tap.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Please select the most appropriate category:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.top, 2)
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("Selected: \(selectedFoodCategory!)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }

    private var classificationResultsList: some View {
        VStack(spacing: 10) {
            ForEach(Array(classificationResults.enumerated()), id: \.offset) { index, result in
                ClassificationResultRow(
                    result: result,
                    index: index,
                    selectedCategory: selectedFoodCategory,
                    onSelection: { category in
                        selectedFoodCategory = category
                        print("📝 Selected food category: \(category)")
                    }
                )
            }
            
            noMatchingCategoryButton
        }
    }

    private var noMatchingCategoryButton: some View {
        Button(action: {
            selectedFoodCategory = "No close-matching category"
            print("📝 Selected: No close-matching category")
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(selectedFoodCategory == "No close-matching category" ? Color.green : Color.gray)
                                .frame(width: 24, height: 24)
                            Image(systemName: "questionmark")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                        
                        Text("None of the above match")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Spacer()
                    }
                    
                    Text("Select this if no category accurately describes this food")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if selectedFoodCategory == "No close-matching category" {
                    VStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("SELECTED")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.gray)
                        .font(.title2)
                }
            }
            .padding(16)
            .background(
                selectedFoodCategory == "No close-matching category"
                    ? Color.green.opacity(0.1)
                    : Color.white
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        selectedFoodCategory == "No close-matching category"
                            ? Color.green
                            : Color.gray.opacity(0.2),
                        lineWidth: selectedFoodCategory == "No close-matching category" ? 2 : 1
                    )
            )
            .shadow(
                color: selectedFoodCategory == "No close-matching category"
                    ? Color.green.opacity(0.2)
                    : Color.gray.opacity(0.1),
                radius: selectedFoodCategory == "No close-matching category" ? 6 : 2,
                x: 0,
                y: selectedFoodCategory == "No close-matching category" ? 3 : 1
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(selectedFoodCategory == "No close-matching category" ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedFoodCategory == "No close-matching category")
        .padding(.top, 8)
    }

    private var classificationBottomInfo: some View {
        HStack {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.blue)
                .font(.caption)
            Text("This category will be used to provide more relevant explanations")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
    }
    private var additiveIdentificationSection: some View {
        Button(action: identifyAdditives) {
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.blue)
                        .font(.system(size: 20))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify & Analyze Additives")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(identifier.isLoading ? "Processing..." : "Find additives and retrieve knowledge")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if identifier.isLoading || isLookingUpKnowledge {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding()
            .background(Color.white)
            .cornerRadius(16)
            .shadow(color: canAnalyze ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1),
                   radius: 8, x: 0, y: 4)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canAnalyze)
        .opacity(canAnalyze ? 1 : 0.6)
    }
    private func knowledgeSection(_ knowledge: [AdditiveKnowledgeManager.AdditiveKnowledge]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Additive Knowledge Results")
                .font(.headline)
            
            if knowledge.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("No food additives found in this ingredient list")
                        .foregroundColor(.green)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Found detailed knowledge for \(knowledge.count) additive\(knowledge.count == 1 ? "" : "s"):")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(knowledge.enumerated()), id: \.element.substance) { index, info in
                            VStack(alignment: .leading, spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Image(systemName: "info.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.system(size: 12))
                                        Text(info.originalQuery)
                                            .font(.body)
                                            .fontWeight(.semibold)
                                        Spacer()
                                    }
                                    
                                    HStack {
                                        Text("Found:")
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .foregroundColor(.secondary)
                                            .frame(minWidth: 55, alignment: .leading)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Text("\"\(info.originalQuery)\" → \"\(info.substance)\"")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                            .italic()
                                        Spacer()
                                    }
                                }
                                
                                if !info.technicalEffect.isEmpty {
                                    HStack(alignment: .top) {
                                        Text("Used for:")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.secondary)
                                            .frame(width: 60, alignment: .leading)
                                        Text(formatTechnicalEffect(info.technicalEffect))
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                }

                                if !info.otherNames.isEmpty {
                                    let formattedOtherNames = formatOtherNames(info.otherNames, originalName: info.substance)
                                    if !formattedOtherNames.isEmpty {
                                        HStack(alignment: .top) {
                                            Text("Other names:")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.secondary)
                                                .frame(width: 60, alignment: .leading)
                                            Text(formattedOtherNames)
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                            Spacer()
                                        }
                                    }
                                }
                                
                                if cfrManager.isLoaded {
                                    let cfrCodes = cfrManager.getCFRCodes(for: info.substance)
                                    if !cfrCodes.isEmpty {
                                        let cfrURLs = cfrManager.generateCFRURLs(for: cfrCodes)
                                        
                                        HStack(alignment: .top) {
                                            Text("CFR Links:")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.secondary)
                                                .frame(width: 60, alignment: .leading)
                                            
                                            VStack(alignment: .leading, spacing: 6) {
                                                ForEach(cfrURLs, id: \.code) { cfrData in
                                                    Button(action: {
                                                        print("🔗 Opening CFR link: \(cfrData.url)")
                                                        UIApplication.shared.open(cfrData.url)
                                                    }) {
                                                        HStack(spacing: 6) {
                                                            Image(systemName: "link.circle.fill")
                                                                .font(.caption)
                                                                .foregroundColor(.blue)
                                                            Text("21 CFR \(cfrData.code)")
                                                                .font(.caption)
                                                                .fontWeight(.medium)
                                                                .underline()
                                                                .foregroundColor(.blue)
                                                            Image(systemName: "arrow.up.right.square")
                                                                .font(.caption2)
                                                                .foregroundColor(.blue)
                                                        }
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(Color.blue.opacity(0.1))
                                                        .cornerRadius(6)
                                                    }
                                                    .buttonStyle(PlainButtonStyle())
                                                }
                                                
                                                if cfrURLs.count > 1 {
                                                    Text("(\(cfrURLs.count) regulations found)")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                        .italic()
                                                }
                                            }
                                            
                                            Spacer()
                                        }
                                    }
                                }
                                
                                if index < knowledge.count - 1 {
                                    Divider()
                                        .padding(.top, 4)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
                
                // Info note about CFR links
                if !knowledge.isEmpty {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Tap CFR links to view federal regulations in your browser")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                
                // Info note about additive types
                if !knowledge.isEmpty {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Tap 'How It Works' at the top to learn about different additive types")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                
                // Generate explanations button
                Button(action: {
                    generateExplanations()
                }) {
                    HStack {
                        if isGeneratingExplanations {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Generating Explanations...")
                        } else {
                            Image(systemName: "text.bubble")
                            Text("Generate User-Friendly Explanations")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isGeneratingExplanations ? Color.gray : Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isGeneratingExplanations || !identifier.isModelLoaded)
                .padding(.top, 8)
                
                Button(action: {
                    saveToHistoryAtStage("After Knowledge Lookup")
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.caption)
                        Text("Save Results")
                            .font(.caption)
                    }
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
                .padding(.top, 8)
            }
            
            if !additiveExplanations.isEmpty {
                explanationSection(additiveExplanations)
                    .padding(.top, 12)
            }
        }
    }
    private func explanationSection(_ explanations: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.fill.questionmark")
                    .foregroundColor(.purple)
                Text("What These Additives Do")
                    .font(.headline)
                
                Spacer()
                
                // NEW: Show token generation speed when available and not generating
                if !identifier.stat.isEmpty && !isGeneratingExplanations {
                    Text(identifier.stat)
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(4)
                }
                
                // NEW: Save button for explanation stage
                if !isGeneratingExplanations {
                    Button(action: {
                        saveToHistoryAtStage("Complete Analysis")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.caption2)
                            Text("Save Complete")
                                .font(.caption2)
                        }
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(4)
                }
                
                if isGeneratingExplanations {
                    // Show a loading indicator while generating
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.leading, 8)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(explanations)
                    .font(.body)
                    .lineSpacing(4)
                
                // Show a blinking cursor if still generating
                if isGeneratingExplanations {
                    HStack(spacing: 2) {
                        Text("▋")
                            .font(.body)
                            .foregroundColor(.purple)
                            .opacity(0.6)
                            .animation(.easeInOut(duration: 0.5).repeatForever(), value: isGeneratingExplanations)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.1))
            .cornerRadius(8)
        }
    }
    private var canAnalyze: Bool {
        identifier.isModelLoaded &&
        knowledgeManager.isReady &&
        !ingredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !identifier.isLoading &&
        !isLookingUpKnowledge
    }
    private var canReset: Bool {
        !identifier.isLoading &&
        !isLookingUpKnowledge &&
        !isGeneratingExplanations &&
        !isLoadingIngredients
    }
    private var canClassifyCategory: Bool {
        foodClassifier.isLoaded &&
        !ingredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isClassifying
    }
    private func identifyAdditives() {
        // Get device information and print to console
        let deviceIdentifier = UIDevice.getDeviceIdentifier()
        let deviceModelName = UIDevice.getDeviceModelName()
        let supportsMLX = UIDevice.supportsMLX()
        let isRunningOnMac = UIDevice.isRunningOnMac()
        
        if isRunningOnMac {
            print("🖥️ Device Check: Running on \(deviceModelName) - MLX Support: \(supportsMLX)")
            print("🖥️ Hardware Identifier: \(deviceIdentifier)")
        } else {
            print("📱 Device Check: \(deviceModelName) (\(deviceIdentifier)) - MLX Support: \(supportsMLX)")
        }
        
        // Check device compatibility
        if !supportsMLX {
            deviceModel = deviceModelName
            showingUnsupportedDeviceAlert = true
            if isRunningOnMac {
                print("❌ Device Check: MLX not supported on this Mac configuration, aborting analysis")
            } else {
                print("❌ Device Check: MLX not supported on \(deviceModelName), aborting analysis")
            }
            return
        }
        
        if isRunningOnMac {
            print("✅ Device Check: Mac supports MLX, proceeding with analysis")
        } else {
            print("✅ Device Check: \(deviceModelName) supports MLX, proceeding with analysis")
        }
        
        isTextEditorFocused = false
        
        // Clear previous results
        additiveKnowledge = nil
        additiveExplanations = ""
        
        Task {
            // STEP 1: Direct knowledge lookup for comma-separated ingredients
            var directlyIdentifiedAdditives: [String] = []
            
            if knowledgeManager.isReady {
                print("🔍 Direct lookup: Starting pre-processing...")
                let parsedIngredients = parseIngredientsByDelimiters(ingredientText)
                print("📋 Direct lookup: Parsed \(parsedIngredients.count) ingredients")
                
                for ingredient in parsedIngredients {
                    if isBasicIngredient(ingredient) {
                        print("🚫 Skipping basic ingredient: '\(ingredient)'")
                        continue
                    }
                    
                    if let knowledge = await knowledgeManager.directLookup(for: ingredient) {
                        directlyIdentifiedAdditives.append(knowledge.originalQuery)
                        print("✅ Direct match found: '\(ingredient)' -> '\(knowledge.substance)'")
                    }
                }
                
                print("📊 Direct lookup: Found \(directlyIdentifiedAdditives.count) additives directly")
            }
            
            // STEP 2: LLM identification (existing workflow)
            let llmIdentifiedAdditives = await identifier.identifyAdditives(ingredientText) ?? []
            
            // STEP 3: Parse any composite additives with parentheses
            var parsedLLMAdditives: [String] = []
            
            for additive in llmIdentifiedAdditives {
                if isBasicIngredient(additive) {
                    print("🚫 Skipping basic ingredient from LLM: '\(additive)'")
                    continue
                }
                
                if additive.contains("(") && additive.contains(")") {
                    print("🔍 Parsing composite additive: '\(additive)'")
                    let parts = parseAdditiveWithParentheses(additive)
                    let filteredParts = parts.filter { !isBasicIngredient($0) }
                    parsedLLMAdditives.append(contentsOf: filteredParts)
                    print("📋 Parsed into: \(filteredParts)")
                } else {
                    parsedLLMAdditives.append(additive)
                }
            }
            
            // STEP 4: Merge results and remove duplicates
            var allAdditives = Set<String>()
            
            for additive in directlyIdentifiedAdditives {
                allAdditives.insert(additive.uppercased())
            }
            
            for additive in parsedLLMAdditives {
                allAdditives.insert(additive.uppercased())
            }
            
            let finalAdditives = Array(allAdditives).sorted()
            
            print("🎯 Final results: \(directlyIdentifiedAdditives.count) from direct lookup + \(parsedLLMAdditives.count) from LLM = \(finalAdditives.count) unique additives")
            
            // Store for internal use but don't display
            identifiedAdditives = finalAdditives
            
            // STEP 5: Automatically perform knowledge lookup
            if !finalAdditives.isEmpty && knowledgeManager.isReady {
                await performKnowledgeLookup(for: finalAdditives)
            } else if finalAdditives.isEmpty {
                // No additives found, set empty knowledge
                additiveKnowledge = []
            }
        }
    }
    private func classifyFoodCategory() {
        guard !ingredientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        isClassifying = true
        classificationResults = []
        selectedFoodCategory = nil // Reset previous selection
        showingCategorySelection = false
        
        Task {
            let results = await foodClassifier.classifyFood(ingredients: ingredientText)
            
            await MainActor.run {
                classificationResults = results ?? []
                isClassifying = false
                
                // Automatically show selection interface if we have results
                if !classificationResults.isEmpty {
                    showingCategorySelection = true
                }
            }
        }
    }
    private func generateExplanations() {
        guard let knowledge = additiveKnowledge,
              !knowledge.isEmpty else { return }
        
        isGeneratingExplanations = true
        additiveExplanations = ""  // Clear previous explanations
        identifier.stat = ""  // Clear previous token speed
        Task {
            // Build comprehensive food information
            var foodInfoComponents: [String] = []
            
            // Add food record information if available
            if let record = currentFoodRecord {
                let productName = record.description.isEmpty ? record.brandedFoodCategory : record.description
                foodInfoComponents.append("Product: \(productName) by \(record.brandOwner)")
            }
            
            // Add user-selected food category if available
            if let selectedCategory = selectedFoodCategory {
                if selectedCategory != "No close-matching category" {
                    foodInfoComponents.append("Food Category: \(selectedCategory)")
                } else {
                    foodInfoComponents.append("Food Category: General/Unspecified")
                }
            }
            
            // Combine all food information
            let foodInfo = foodInfoComponents.isEmpty ? "Food product" : foodInfoComponents.joined(separator: " | ")
            
            let result = await identifier.generateAdditiveExplanations(
                knowledge: knowledge,
                foodInfo: foodInfo,
                originalIngredients: ingredientText,
                streamingUpdate: { partialText in
                    // Update the UI with streaming text
                    additiveExplanations = partialText
                }
            )
            
            // Final update with complete text (in case there's any difference)
            if let finalResult = result {
                additiveExplanations = finalResult
            }
            
            isGeneratingExplanations = false
        }
    }
    private func saveToHistory() {
        guard let additives = identifiedAdditives else { return }
        
        withAnimation {
            let newItem = Item(context: viewContext)
            newItem.timestamp = Date()
            newItem.ingredientText = ingredientText
            
            // Combine LLM results and knowledge results
            var resultText = "LLM identified: \(additives.joined(separator: ", "))"
            
            if let knowledge = additiveKnowledge, !knowledge.isEmpty {
                let knowledgeSummary = knowledge.map { "\($0.substance) (\($0.technicalEffect))" }.joined(separator: ", ")
                resultText += "\nKnowledge: \(knowledgeSummary)"
            }
            
            newItem.analysisResult = resultText
            
            do {
                try viewContext.save()
                showingSaveSuccess = true
            } catch {
                let nsError = error as NSError
                print("Error saving to history: \(nsError), \(nsError.userInfo)")
            }
        }
    }
    private func resetAppContent() {
        // Clear all text content
        ingredientText = ""
        additiveExplanations = ""
        
        // Clear all results
        identifiedAdditives = nil
        additiveKnowledge = nil
        classificationResults = []
        selectedFoodCategory = nil
        showingCategorySelection = false
        
        // Clear current food record and related states
        currentFoodRecord = nil  // This will hide the food record info section
        showingEntryId = nil
        entryIdError = nil
        selectedEntryId = ""
        
        // Clear focus states
        isTextEditorFocused = false
        isEntryIdFocused = false
        
        print("🔄 App content reset successfully")
    }
    private func saveToHistoryAtStage(_ stage: String) {
        withAnimation {
            let newItem = Item(context: viewContext)
            newItem.timestamp = Date()
            newItem.ingredientText = ingredientText
            newItem.stage = stage
            
            // Save data based on current stage
            if let additives = identifiedAdditives {
                newItem.identifiedAdditives = additives.joined(separator: "|")
                newItem.analysisResult = "Identified \(additives.count) additives"
            }
            
            if let knowledge = additiveKnowledge {
                let knowledgeData = knowledge.map { k in
                    "\(k.originalQuery)→\(k.substance)→\(k.technicalEffect)"
                }.joined(separator: "|||")
                newItem.knowledgeData = knowledgeData
            }
            
            if !additiveExplanations.isEmpty {
                newItem.explanations = additiveExplanations
            }
            
            // Add food record info if available
            if let record = currentFoodRecord {
                newItem.analysisResult = (newItem.analysisResult ?? "") +
                    "\nProduct: \(record.description.isEmpty ? record.brandedFoodCategory : record.description) by \(record.brandOwner)"
            }
            
            do {
                try viewContext.save()
                showingSaveSuccess = true
            } catch {
                let nsError = error as NSError
                print("Error saving to history: \(nsError), \(nsError.userInfo)")
            }
        }
    }
    private func parseIngredientsByDelimiters(_ text: String) -> [String] {
        // Replace parentheses with commas to use them as delimiters
        let textWithCommas = text
            .replacingOccurrences(of: "(", with: ",")
            .replacingOccurrences(of: ")", with: ",")
        
        // Split by comma and clean each ingredient
        let ingredients = textWithCommas.components(separatedBy: ",")
            .map { ingredient in
                ingredient
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^\s*AND\s+"#, with: "", options: .regularExpression) // Remove leading "AND"
            }
            .filter { !$0.isEmpty }
            .filter { $0.count > 1 } // Filter out single characters that might result from splitting
        
        return ingredients
    }
    private func processImageWithOCR(_ image: UIImage) {
        isProcessingOCR = true
        
        Task {
            guard let cgImage = image.cgImage else {
                isProcessingOCR = false
                return
            }
            
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    isProcessingOCR = false
                    return
                }
                
                // Combine all recognized text
                let recognizedText = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: " ")
                
                // Update UI on main thread
                DispatchQueue.main.async {
                    // Clean and format the text for ingredient lists
                    let cleanedText = self.cleanOCRText(recognizedText)
                    self.ingredientText = cleanedText
                    
                    // Clear any existing food record info since this is from OCR
                    self.currentFoodRecord = nil
                    self.showingEntryId = nil
                    
                    self.isProcessingOCR = false
                    self.isTextEditorFocused = false
                }
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let requestHandler = VNImageRequestHandler(cgImage: cgImage)
            try? requestHandler.perform([request])
        }
    }
    private func parseAdditiveWithParentheses(_ text: String) -> [String] {
        var results: [String] = []
        
        // Find the position of opening parenthesis
        if let openParen = text.firstIndex(of: "("),
           let closeParen = text.lastIndex(of: ")") {
            
            // Extract the part before parentheses
            let mainPart = String(text[..<openParen])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Only add main part if it's a valid additive (not just a descriptor)
            let mainPartLower = mainPart.lowercased()
            if !mainPartLower.isEmpty &&
               !mainPartLower.contains("contains") &&
               !mainPartLower.contains("including") &&
               !mainPartLower.contains("such as") {
                results.append(mainPart)
            }
            
            // Extract the content inside parentheses
            let startIndex = text.index(after: openParen)
            if startIndex < closeParen {
                let insideContent = String(text[startIndex..<closeParen])
                
                // Split the inside content by commas and clean each part
                let insideParts = insideContent.components(separatedBy: ",")
                    .map { part in
                        part.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: #"^\s*AND\s+"#, with: "", options: .regularExpression)
                    }
                    .filter { !$0.isEmpty }
                
                results.append(contentsOf: insideParts)
            }
        } else {
            // No parentheses found, return as-is
            results.append(text)
        }
        
        return results
    }
    private func isBasicIngredient(_ ingredient: String) -> Bool {
        let cleaned = ingredient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // List of basic ingredients that are not food additives
        let basicIngredients: Set<String> = [
            "sugar", "cane sugar", "brown sugar", "white sugar", "granulated sugar",
            "flour", "wheat flour", "water", "salt", "oil", "milk", "eggs", "butter",
            "honey", "molasses", "corn syrup", "rice", "oats", "barley"
        ]
        
        return basicIngredients.contains(cleaned)
    }
    private func cleanOCRText(_ text: String) -> String {
        // Remove extra whitespace and clean up common OCR issues
        var cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try to identify and format as ingredient list
        // Look for common patterns like "INGREDIENTS:" or "Contains:"
        if let range = cleaned.range(of: "INGREDIENTS:", options: .caseInsensitive) {
            cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let range = cleaned.range(of: "CONTAINS:", options: .caseInsensitive) {
            cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Convert to uppercase to match your sample format
        return cleaned.uppercased()
    }
    private func performKnowledgeLookup(for additives: [String]) async {
        isLookingUpKnowledge = true
        
        defer {
            isLookingUpKnowledge = false
        }
        
        var knowledgeResults: [AdditiveKnowledgeManager.AdditiveKnowledge] = []
        var processedAdditives = Set<String>()
        
        for additive in additives {
            let upperAdditive = additive.uppercased()
            
            if processedAdditives.contains(upperAdditive) {
                continue
            }
            processedAdditives.insert(upperAdditive)
            
            if let directKnowledge = await knowledgeManager.directLookup(for: upperAdditive) {
                knowledgeResults.append(AdditiveKnowledgeManager.AdditiveKnowledge(
                    originalQuery: directKnowledge.originalQuery,
                    substance: formatChemicalName(directKnowledge.substance),
                    otherNames: directKnowledge.otherNames,
                    technicalEffect: directKnowledge.technicalEffect
                ))
                print("✅ Native: Found via direct lookup: '\(upperAdditive)'")
            } else {
                let searchResults = await knowledgeManager.lookupAdditiveKnowledge(for: [upperAdditive])
                if let knowledge = searchResults.first {
                    knowledgeResults.append(AdditiveKnowledgeManager.AdditiveKnowledge(
                        originalQuery: knowledge.originalQuery,
                        substance: formatChemicalName(knowledge.substance),
                        otherNames: knowledge.otherNames,
                        technicalEffect: knowledge.technicalEffect
                    ))
                    print("✅ Native: Found via embedding search: '\(upperAdditive)'")
                }
            }
        }
        
        additiveKnowledge = knowledgeResults
    }
    private func testWithTrainingExamples() {
        print("🧪 Testing with examples similar to training data...")
        
        // Use examples that should match your training categories well
        let trainingLikeExamples = [
            ("sugar, corn syrup, water, citric acid, artificial flavors, colors", "Expected: Candy"),
            ("wheat flour, water, yeast, salt, sugar", "Expected: Breads & Buns"),
            ("milk, sugar, cream, vanilla, eggs", "Expected: Ice Cream"),
            ("oats, sugar, honey, nuts, dried fruit", "Expected: Breakfast Cereals"),
            ("tomatoes, onions, garlic, basil, olive oil", "Expected: Sauces"),
            ("chicken, salt, pepper, herbs", "Expected: Poultry"),
            ("chocolate, sugar, milk, cocoa butter", "Expected: Candy/Chocolate"),
            ("rice, water, salt", "Expected: Rice & Grain Products")
        ]
        
        for (ingredients, expected) in trainingLikeExamples {
            print("\n--- Testing: \(expected) ---")
            print("Input: \(ingredients)")
            
            Task {
                if let results = await foodClassifier.classifyFood(ingredients: ingredients) {
                    print("Prediction: \(results[0].category) (\(String(format: "%.1f", results[0].confidence * 100))%)")
                    print("Top 3:")
                    for (i, result) in results.enumerated() {
                        print("  \(i+1). \(result.category): \(String(format: "%.1f", result.confidence * 100))%")
                    }
                }
            }
        }
    }
}
// MARK: - Classification Result Row
struct ClassificationResultRow: View {
    let result: ClassificationResult
    let index: Int
    let selectedCategory: String?
    let onSelection: (String) -> Void
    
    private var isSelected: Bool {
        selectedCategory == result.category
    }
    
    var body: some View {
        Button(action: {
            onSelection(result.category)
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        // Category ranking
                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.green : Color.orange)
                                .frame(width: 24, height: 24)
                            Text("\(index + 1)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                        
                        Text(result.category)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Text("\(String(format: "%.1f", result.confidence * 100))%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(isSelected ? .green : .orange)
                    }
                    
                    // Confidence bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 6)
                                .cornerRadius(3)
                            
                            Rectangle()
                                .fill(isSelected ? Color.green : Color.orange)
                                .frame(width: geometry.size.width * CGFloat(result.confidence), height: 6)
                                .cornerRadius(3)
                        }
                    }
                    .frame(height: 6)
                }
                
                // Selection indicator
                if isSelected {
                    VStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("SELECTED")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.gray)
                        .font(.title2)
                }
            }
            .padding(16)
            .background(
                isSelected
                    ? Color.green.opacity(0.1)
                    : Color.white
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? Color.green
                            : Color.gray.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(
                color: isSelected
                    ? Color.green.opacity(0.2)
                    : Color.gray.opacity(0.1),
                radius: isSelected ? 6 : 2,
                x: 0,
                y: isSelected ? 3 : 1
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - History View
struct HistoryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Item.timestamp, ascending: false)],
        animation: .default)
    private var historyItems: FetchedResults<Item>
    
    @State private var expandedItems: Set<NSManagedObjectID> = []
    
    var body: some View {
        NavigationView {
            List {
                ForEach(historyItems) { item in
                    historyRowView(for: item)
                }
                .onDelete(perform: deleteItems)
            }
            .navigationTitle("Analysis History")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
        }
    }
    
    private func historyRowView(for item: Item) -> some View {
        let isExpanded = expandedItems.contains(item.objectID)
        
        return VStack(alignment: .leading, spacing: 8) {
            // Header row - always visible
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.timestamp ?? Date(), formatter: itemFormatter)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if let stage = item.stage {
                            Text("• \(stage)")
                                .font(.caption)
                                .foregroundColor(colorForStage(stage))
                                .fontWeight(.medium)
                        }
                    }
                    
                    Text(item.analysisResult ?? "No summary")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(isExpanded ? nil : 2)
                }
                
                Spacer()
                
                Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                    .foregroundColor(.blue)
                    .font(.title3)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3)) {
                    if isExpanded {
                        expandedItems.remove(item.objectID)
                    } else {
                        expandedItems.insert(item.objectID)
                    }
                }
            }
            
            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Ingredients
                    if let ingredients = item.ingredientText, !ingredients.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Ingredients", systemImage: "list.bullet")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            
                            Text(ingredients)
                                .font(.caption)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }
                    }
                    
                    // Identified Additives
                    if let additivesString = item.identifiedAdditives, !additivesString.isEmpty {
                        let additives = additivesString.components(separatedBy: "|")
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Identified Additives (\(additives.count))", systemImage: "magnifyingglass")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                            
                            ForEach(additives, id: \.self) { additive in
                                HStack {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundColor(.blue)
                                    Text(additive)
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    
                    // Knowledge Data
                    if let knowledgeString = item.knowledgeData, !knowledgeString.isEmpty {
                        let knowledgeItems = knowledgeString.components(separatedBy: "|||")
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Knowledge Details", systemImage: "book.fill")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                            
                            ForEach(knowledgeItems, id: \.self) { knowledge in
                                let parts = knowledge.components(separatedBy: "→")
                                if parts.count >= 3 {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(parts[0])
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Text(parts[2])
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                    .padding(6)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(4)
                                }
                            }
                        }
                    }
                    
                    // Explanations
                    if let explanations = item.explanations, !explanations.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("User-Friendly Explanation", systemImage: "text.bubble")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.purple)
                            
                            Text(explanations)
                                .font(.caption)
                                .padding(8)
                                .background(Color.purple.opacity(0.1))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
    
    private func colorForStage(_ stage: String) -> Color {
        switch stage {
        case "Ingredients Only": return .gray
        case "After Identification": return .blue
        case "After Knowledge Lookup": return .orange
        case "Complete Analysis": return .purple
        default: return .secondary
        }
    }
    
    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { historyItems[$0] }.forEach(viewContext.delete)
            
            do {
                try viewContext.save()
            } catch {
                let nsError = error as NSError
                print("Error deleting items: \(nsError), \(nsError.userInfo)")
            }
        }
    }
    
}

// MARK: - Helper

private let itemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

// MARK: - Preview

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

// MARK: - MLX Additive Identifier Service

@Observable
@MainActor
class MLXAdditiveIdentifier {
     
    var isLoading = false
    var isModelLoaded = false
    var errorMessage: String?
    var modelInfo = ""
    var stat = ""
    var currentStage: String = ""
    let generateParameters = GenerateParameters(maxTokens: 1000, temperature: 0.3)
    let bundledModelPath = "Llama-3.2-3B-Instruct-4bit"
    
    enum LoadState {
        case idle
        case loaded(ModelContainer)
    }
    
    var loadState = LoadState.idle
    var generationTask: Task<Void, Error>?
    
    init() {
        // Use higher priority and regular Task instead of Task.detached
        Task(priority: .userInitiated) { [weak self] in
            await self?.initializeModel()
        }
    }

    private func initializeModel() async {
        do {
            print("🚀 MLXAdditiveIdentifier: Starting initialization...")
            
            _ = try await load()
            
            print("✅ MLXAdditiveIdentifier: Initialization completed successfully")
        } catch {
            print("❌ MLXAdditiveIdentifier: Initialization failed with error: \(error)")
            await MainActor.run { [weak self] in
                self?.errorMessage = "Init failed: \(error.localizedDescription)"
                self?.isLoading = false
            }
        }
    }
    
    /// Load model from bundle - no download required
    func load() async throws -> ModelContainer {
        switch loadState {
        case .idle:
            print("📱 MLX Load: Starting model loading process...")
            await MainActor.run {
                isLoading = true
            }
            
            // Set memory limits for iOS
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            
            // Get the bundled model directory URL
            guard let bundleResourceURL = Bundle.main.resourceURL else {
                throw MLXError.modelNotFound("Bundle resource URL not found")
            }
            
            let modelDirectoryURL = bundleResourceURL.appendingPathComponent(bundledModelPath)
            
            // Quick existence check without extensive logging
            guard FileManager.default.fileExists(atPath: modelDirectoryURL.path) else {
                throw MLXError.modelNotFound("Bundled model directory not found at path: \(modelDirectoryURL.path)")
            }
            
            // Create model configuration
            let modelConfiguration = ModelConfiguration(directory: modelDirectoryURL)
            
            // Load model container - this is the main bottleneck
            let modelContainer = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            ) { progress in
                // Reduce UI updates during loading
                if Int(progress.fractionCompleted * 100) % 10 == 0 {
                    Task { @MainActor in
                        self.modelInfo = "Loading: \(Int(progress.fractionCompleted * 100))%"
                    }
                }
            }
            
            // Get model parameters
            let numParams = await modelContainer.perform { context in
                context.model.numParameters()
            }
            
            let paramsMB = numParams / (1024*1024)
            
            await MainActor.run {
                self.modelInfo = "Loaded bundled model. Weights: \(paramsMB)M"
                self.loadState = .loaded(modelContainer)
                self.isModelLoaded = true
                self.isLoading = false
                self.errorMessage = nil
            }
            
            print("🎉 MLX Load: Model loading completed successfully!")
            return modelContainer
            
        case .loaded(let modelContainer):
            return modelContainer
        }
    }
    
    func identifyAdditives(_ ingredientText: String) async -> [String]? {
        print("🔍 MLX Identify: Starting additive identification...")
        
        guard !isLoading else {
            print("⏳ MLX Identify: Model is still loading, aborting...")
            errorMessage = "Model is still loading"
            return nil
        }
        
        print("🔄 MLX Identify: Setting loading state...")
        isLoading = true
        defer {
            print("🔚 MLX Identify: Resetting loading state...")
            isLoading = false
        }
        
        print("📝 MLX Identify: ORIGINAL INGREDIENT TEXT:")
        print("========================================")
        print(ingredientText)
        print("========================================")
        print("📊 MLX Identify: Text length: \(ingredientText.count) characters")
        
        do {
            print("📦 MLX Identify: Getting model container...")
            let modelContainer = try await load()
            print("✅ MLX Identify: Model container obtained successfully")
            
            // Single stage identification with enhanced parsing
            print("🤖 Identifying additives...")
            let result = try await performLLMCall(
                modelContainer: modelContainer,
                systemPrompt: getIdentificationPrompt(),
                userPrompt: "Ingredient List: \(ingredientText)",
                stage: "Additive Identification"
            )
            
            // Parse results with enhanced parsing
            let identifiedAdditives = parseAdditiveList(result)
            print("📋 MLX: Found \(identifiedAdditives.count) potential additives: \(identifiedAdditives)")
            
            return identifiedAdditives
            
        } catch {
            let errorMsg = "Identification failed: \(error.localizedDescription)"
            print("❌ MLX Identify: \(errorMsg)")
            print("🔍 MLX Identify: Detailed error: \(error)")
            errorMessage = errorMsg
            return nil
        }
    }
    func generateAdditiveExplanations(
        knowledge: [AdditiveKnowledgeManager.AdditiveKnowledge],
        foodInfo: String,
        originalIngredients: String,
        streamingUpdate: @escaping (String) -> Void
    ) async -> String? {
        print("📝 MLX Explain: Starting additive explanation generation...")
        
        guard !isLoading else {
            print("⏳ MLX Explain: Model is still loading, aborting...")
            errorMessage = "Model is still loading"
            return nil
        }
        
        isLoading = true
        defer {
            isLoading = false
        }
        
        do {
            let modelContainer = try await load()
            
            // Prepare the knowledge data for the LLM
            let additiveInfo = knowledge.map { k in
                "\(k.originalQuery): \(k.technicalEffect)"
            }.joined(separator: "\n")
            
            let userPrompt = """
            Food Information: \(foodInfo)
            
            Original Ingredients: \(originalIngredients)
            
            Additives and their technical effects:
            \(additiveInfo)
            """
            
            print("🤖 STAGE 3: Generating user-friendly explanations...")
            let explanation = try await performLLMCall(
                modelContainer: modelContainer,
                systemPrompt: getExplanationPrompt(),
                userPrompt: userPrompt,
                stage: "Agent 3 (Explanation)",
                streamingUpdate: streamingUpdate
            )
            
            print("✅ MLX Explain: Generated explanation successfully")
            return explanation
            
        } catch {
            let errorMsg = "Explanation generation failed: \(error.localizedDescription)"
            print("❌ MLX Explain: \(errorMsg)")
            errorMessage = errorMsg
            return nil
        }
    }
    private func performLLMCall(
        modelContainer: ModelContainer,
        systemPrompt: String,
        userPrompt: String,
        stage: String,
        streamingUpdate: ((String) -> Void)? = nil
    ) async throws -> String {
        // Update the current stage
        await MainActor.run {
            self.currentStage = stage
        }
        
        // Generate new seed for each request
        let seed = UInt64(Date.timeIntervalSinceReferenceDate * 1000)
        print("🎲 MLX \(stage): Setting random seed: \(seed)")
        MLXRandom.seed(seed)
        
        let combinedPrompt = "\(systemPrompt)\n\n\(userPrompt)"
        print("📝 MLX \(stage): Combined prompt length: \(combinedPrompt.count) characters")
        if stage.contains("Agent 3") {
            print("🎯 MLX \(stage): FULL PROMPT BEING SENT:")
            print("=====================================")
            print(combinedPrompt)
            print("=====================================")
        }
        
        // Collect response chunks
        var responseChunks: [String] = []
        var finalStat = ""
        
        print("🚀 MLX \(stage): Starting model inference...")
        try await modelContainer.perform { context in
            print("⚙️ MLX \(stage): Preparing input...")
            let input = try await context.processor.prepare(input: UserInput(prompt: combinedPrompt))
            print("✅ MLX \(stage): Input prepared successfully")
            
            print("🔥 MLX \(stage): Starting generation stream...")
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: generateParameters,
                context: context
            )
            
            print("📡 MLX \(stage): Processing generation stream...")
            var chunkCount = 0
            for await batch in stream {
                if let chunk = batch.chunk {
                    responseChunks.append(chunk)
                    chunkCount += 1
                    
                    // Call streaming update if provided
                    if let streamingUpdate = streamingUpdate {
                        await MainActor.run {
                            streamingUpdate(responseChunks.joined())
                        }
                    }
                    
                    if chunkCount % 10 == 0 {
                        print("📊 MLX \(stage): Processed \(chunkCount) chunks...")
                    }
                }
                
                if let completion = batch.info {
                    finalStat = String(format: "%.2f tokens/s", completion.tokensPerSecond)
                    print("⚡ MLX \(stage): Token generation speed: \(finalStat)")
                }
            }
            print("✅ MLX \(stage): Generation stream completed. Total chunks: \(chunkCount)")
        }
        
        // Clear the current stage when done
        await MainActor.run {
            self.currentStage = ""
        }
        
        if stage.contains("Agent 2") || stage.contains("Agent 3") {
            await MainActor.run {
                self.stat = finalStat
                print("📈 MLX: Updated UI stats: \(finalStat)")
            }
        }
        
        // Combine response chunks
        let fullResponse = responseChunks.joined()
        print("📋 MLX \(stage): Full response length: \(fullResponse.count) characters")
        
        // 🔍 Print the complete LLM response for debugging
        print("🤖 MLX \(stage): COMPLETE LLM RESPONSE:")
        print("========================================")
        print(fullResponse)
        print("========================================")
        
        return fullResponse
    }
    private func getIdentificationPrompt() -> String {
        return """
        You are a food science expert. Identify ONLY the food additives from the ingredient list.
        
        IMPORTANT OUTPUT FORMAT:
        - List one additive per line
        - NO numbering, bullets, or prefixes
        - Just the additive name on each line
        - If no additives found, return only: NONE
        
        WHAT TO INCLUDE:
        - Preservatives (e.g., sodium benzoate, calcium propionate)
        - Emulsifiers (e.g., lecithin, mono- and diglycerides)
        - Stabilizers and thickeners (e.g., xanthan gum, carrageenan)
        - Artificial colors (e.g., Red 40, Yellow 5)
        - Artificial flavors and flavor enhancers
        - Chemical leavening agents (e.g., sodium bicarbonate)
        - Antioxidants (e.g., BHA, BHT, ascorbic acid)
        - pH control agents (e.g., citric acid, phosphoric acid)
        
        WHAT TO EXCLUDE:
        - Basic ingredients: flour, water, sugar, salt, oil, milk, eggs
        - Natural foods: fruits, vegetables, meats, grains
        - Common spices and herbs
        
        EXAMPLE OUTPUT:
        Sodium Benzoate
        Xanthan Gum
        Red 40
        Citric Acid
        """
    }
    private func getExplanationPrompt() -> String {
        return """
        You are a friendly food science educator explaining food additives to everyday consumers.
        Your task is to explain what the additives do in simple, easy-to-understand language.
        RULES:
        - Use the exact additive names as they appear in the original ingredients list
        - Explain in plain English what each additive does for this specific food
        - Keep explanations brief (1-2 sentences per additive)
        - Focus on why the additive is used, not its chemical properties
        - Be reassuring but factual
        - Group similar additives if it makes sense
        - Use the food context to make explanations more relevant
        """
    }
    private func parseAdditiveList(_ response: String) -> [String] {
        // Clean the response
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if the response indicates no additives
        if trimmedResponse.uppercased().contains("NONE") ||
           trimmedResponse.isEmpty ||
           trimmedResponse.uppercased().contains("NO ADDITIVES") ||
           trimmedResponse.uppercased().contains("NO FOOD ADDITIVES") {
            return []
        }
        
        // Split by various delimiters
        let lines = trimmedResponse
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        
        var additives: [String] = []
        
        for line in lines {
            var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty lines
            if cleaned.isEmpty { continue }
            
            // Remove common prefixes and formatting
            // Remove numbering: "1. ", "2) ", "1) ", "- ", "* ", "• "
            cleaned = cleaned.replacingOccurrences(of: #"^[\d]+[.)]\s*"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
            
            // Remove "Additive:" or similar prefixes
            cleaned = cleaned.replacingOccurrences(of: #"^(Additive|Chemical|Preservative|Emulsifier|Color|Stabilizer):\s*"#,
                                                 with: "", options: [.regularExpression, .caseInsensitive])
            
            // Trim again after removing prefixes
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip if it's a category header or instruction
            let skipPatterns = [
                "following", "additives", "identified", "found", "list",
                "includes", "contains", "ingredients", "analysis", "none",
                "food additive", "chemical", "preservative", "emulsifier"
            ]
            
            let cleanedLower = cleaned.lowercased()
            let shouldSkip = skipPatterns.contains { pattern in
                cleanedLower.contains(pattern) && cleanedLower.count < 30
            }
            
            if shouldSkip { continue }
            
            // Additional validation - must be at least 2 characters
            if cleaned.count >= 2 {
                // Handle parenthetical content
                if cleaned.contains("(") && cleaned.contains(")") {
                    // Extract the main additive name (before parentheses)
                    if let parenIndex = cleaned.firstIndex(of: "(") {
                        let mainPart = String(cleaned[..<parenIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if mainPart.count >= 2 {
                            additives.append(mainPart)
                        }
                    }
                } else {
                    additives.append(cleaned)
                }
            }
        }
        
        // Remove duplicates and return
        return Array(Set(additives)).sorted()
    }
    
    private func formatChemicalName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If it's all uppercase, convert to title case
        if trimmed == trimmed.uppercased() {
            return trimmed.capitalized
        }
        
        // If it's already properly formatted, return as-is
        return trimmed
    }
    
    func cancelGeneration() {
        generationTask?.cancel()
        isLoading = false
    }
}

// MARK: - Custom Errors

enum MLXError: Error, LocalizedError {
    case modelNotFound(String)
    case timeout(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound(let message):
            return "Model not found: \(message)"
        case .timeout(let message):
            return "Timeout: \(message)"
        }
    }
}

// MARK: - Native Additive Knowledge Manager

@Observable
@MainActor
class AdditiveKnowledgeManager {
    
    struct AdditiveKnowledge {
        let originalQuery: String
        let substance: String
        let otherNames: String
        let technicalEffect: String
    }
    private let colorMappings: [String: String] = [
        // Blue colors
        "blue 1": "FD&C BLUE NO. 1",
        "blue 1 lake": "FD&C BLUE NO. 1, ALUMINUM LAKE",
        "blue 1 aluminum lake": "FD&C BLUE NO. 1, ALUMINUM LAKE",
        "blue 1 calcium lake": "FD&C BLUE NO. 1, CALCIUM LAKE",
        "blue 2": "FD&C BLUE NO. 2",
        "blue 2 lake": "FD&C BLUE NO. 2, CALCIUM LAKE",
        "blue 2 calcium lake": "FD&C BLUE NO. 2, CALCIUM LAKE",
        
        // Yellow colors
        "yellow 5": "FD&C YELLOW NO. 5",
        "yellow 5 lake": "FD&C YELLOW NO. 5, ALUMINUM LAKE",
        "yellow 5 aluminum lake": "FD&C YELLOW NO. 5, ALUMINUM LAKE",
        "yellow 5 calcium lake": "FD&C YELLOW NO. 5, CALCIUM LAKE",
        "yellow 6": "FD&C YELLOW NO. 6",
        "yellow 6 lake": "FD&C YELLOW NO. 6, ALUMINUM LAKE",
        "yellow 6 aluminum lake": "FD&C YELLOW NO. 6, ALUMINUM LAKE",
        "yellow 6 calcium lake": "FD&C YELLOW NO. 6, CALCIUM LAKE",
        
        // Red colors
        "red 3": "FD&C RED NO. 3",
        "red 40": "FD&C RED NO. 40",
        "red 40 lake": "FD&C RED NO. 40, ALUMINUM LAKE",
        "red 40 aluminum lake": "FD&C RED NO. 40, ALUMINUM LAKE",
        "red 40 calcium lake": "FD&C RED NO. 40, CALCIUM LAKE",
        
        // Green colors
        "green 3": "FD&C GREEN NO. 3",
        "green 3 lake": "FD&C GREEN NO. 3, ALUMINUM LAKE",
        "green 3 aluminum lake": "FD&C GREEN NO. 3, ALUMINUM LAKE",
        "green 3 calcium lake": "FD&C GREEN NO. 3, CALCIUM LAKE",
        
        // Common variations
        "fd&c blue 1": "FD&C BLUE NO. 1",
        "fd&c yellow 5": "FD&C YELLOW NO. 5",
        "fd&c red 40": "FD&C RED NO. 40"
    ]
    private let flavorMappings: [String: AdditiveKnowledge] = [
        "natural flavors": AdditiveKnowledge(
            originalQuery: "natural flavors",
            substance: "Natural Flavors",
            otherNames: "Natural Flavor, Flavoring",
            technicalEffect: "Natural flavors are derived from plants, animals, or microorganisms and are used to enhance or add taste to food products. They must come from natural sources but can be processed or concentrated."
        ),
        "natural flavor": AdditiveKnowledge(
            originalQuery: "natural flavor",
            substance: "Natural Flavor",
            otherNames: "Natural Flavors, Flavoring",
            technicalEffect: "Natural flavors are derived from plants, animals, or microorganisms and are used to enhance or add taste to food products. They must come from natural sources but can be processed or concentrated."
        ),
        "artificial flavors": AdditiveKnowledge(
            originalQuery: "artificial flavors",
            substance: "Artificial Flavors",
            otherNames: "Artificial Flavor, Artificial Flavoring",
            technicalEffect: "Artificial flavors are chemically synthesized compounds that mimic natural flavors. They are used to enhance or add taste to food products and are often more consistent and cost-effective than natural alternatives."
        ),
        "artificial flavor": AdditiveKnowledge(
            originalQuery: "artificial flavor",
            substance: "Artificial Flavor",
            otherNames: "Artificial Flavors, Artificial Flavoring",
            technicalEffect: "Artificial flavors are chemically synthesized compounds that mimic natural flavors. They are used to enhance or add taste to food products and are often more consistent and cost-effective than natural alternatives."
        ),
        "natural and artificial flavors": AdditiveKnowledge(
            originalQuery: "natural and artificial flavors",
            substance: "Natural and Artificial Flavors",
            otherNames: "Mixed Flavors, Natural & Artificial Flavoring",
            technicalEffect: "A combination of natural flavors (derived from natural sources) and artificial flavors (chemically synthesized). This blend allows manufacturers to achieve desired taste profiles while balancing cost and consistency."
        ),
        "natural and artificial flavor": AdditiveKnowledge(
            originalQuery: "natural and artificial flavor",
            substance: "Natural and Artificial Flavor",
            otherNames: "Mixed Flavor, Natural & Artificial Flavoring",
            technicalEffect: "A combination of natural flavors (derived from natural sources) and artificial flavors (chemically synthesized). This blend allows manufacturers to achieve desired taste profiles while balancing cost and consistency."
        )
    ]
    // Internal structure for embeddings
    private struct EmbeddingRecord {
        let substance: String
        let otherNames: String
        let technicalEffect: String
        let searchableText: String
        let embedding: [Float]
    }
    
    private var embeddingRecords: [EmbeddingRecord] = []
    private var embeddingDimension: Int = 0
    
    var isInitialized = false
    var isLoading = false
    
    // THRESHOLD CONFIGURATION
    // Adjust this value to control match quality:
    // - 0.2: Very lenient (accepts weak matches)
    // - 0.35: Balanced (recommended)
    // - 0.5: Strict (only strong matches)
    // - 0.7: Very strict (only very strong matches)
    private let matchThreshold: Float = 0.244
    
    // Public property to check if ready
    var isReady: Bool { isInitialized && !isLoading && !embeddingRecords.isEmpty }
    
    init() {
        Task(priority: .userInitiated) { [weak self] in
            await self?.loadEmbeddings()
        }
    }
    
    private func loadEmbeddings() async {
        guard !isInitialized && !isLoading else { return }
        isLoading = true
        
        print("🔄 Native: Loading food additive embeddings...")
        
        do {
            // Load the JSON file from bundle
            guard let path = Bundle.main.path(forResource: "food_additive_embeddings", ofType: "json") else {
                print("❌ Native: food_additive_embeddings.json not found in bundle")
                isLoading = false
                return
            }
            
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            
            embeddingDimension = json["embedding_dimension"] as? Int ?? 0
            let totalRecords = json["total_records"] as? Int ?? 0
            let dataArray = json["data"] as? [[String: Any]] ?? []
            
            print("📊 Native: Loading \(totalRecords) records with \(embeddingDimension)-dimensional embeddings")
            
            // Parse embedding records
            var records: [EmbeddingRecord] = []
            
            for item in dataArray {
                guard let substance = item["substance"] as? String,
                      let otherNames = item["other_names"] as? String,
                      let technicalEffect = item["technical_effect"] as? String,
                      let searchableText = item["searchable_text"] as? String,
                      let embeddingArray = item["embedding"] as? [Double] else {
                    continue
                }
                
                // Convert Double array to Float array for better performance
                let embedding = embeddingArray.map { Float($0) }
                
                records.append(EmbeddingRecord(
                    substance: substance,
                    otherNames: otherNames,
                    technicalEffect: technicalEffect,
                    searchableText: searchableText,
                    embedding: embedding
                ))
            }
            
            embeddingRecords = records
            isInitialized = true
            
            print("✅ Native: Loaded \(embeddingRecords.count) additive records successfully")
            
        } catch {
            print("❌ Native: Failed to load embeddings: \(error)")
        }
        
        isLoading = false
    }
    
    // Look up knowledge for identified additives
    func lookupAdditiveKnowledge(for identifiedAdditives: [String]) async -> [AdditiveKnowledge] {
        guard isReady else {
            print("❌ Native: Not ready for search")
            return []
        }
        
        print("🔍 Native: Looking up knowledge for \(identifiedAdditives.count) identified additives...")
        
        var foundKnowledge: [AdditiveKnowledge] = []
        
        for additive in identifiedAdditives {
            if let knowledge = await searchKnowledge(for: additive) {
                // 🆕 CREATE NEW KNOWLEDGE WITH ORIGINAL QUERY
                let knowledgeWithQuery = AdditiveKnowledge(
                    originalQuery: additive,  // 🆕 STORE ORIGINAL QUERY
                    substance: knowledge.substance,
                    otherNames: knowledge.otherNames,
                    technicalEffect: knowledge.technicalEffect
                )
                foundKnowledge.append(knowledgeWithQuery)
                print("✅ Native: Found knowledge for '\(additive)' -> '\(knowledge.substance)'")
            } else {
                print("❌ Native: No knowledge found for '\(additive)'")
            }
        }
        
        print("📋 Native: Retrieved knowledge for \(foundKnowledge.count)/\(identifiedAdditives.count) additives")
        return foundKnowledge
    }
    // Direct lookup without embedding search - for pre-processing
    func directLookup(for ingredient: String) async -> AdditiveKnowledge? {
        guard isReady else { return nil }
        
        // Clean the ingredient
        let cleaned = ingredient
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(preservative)", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let lowercased = cleaned.lowercased()
        
        // Check flavor mappings first
        if let flavorKnowledge = flavorMappings[lowercased] {
            return AdditiveKnowledge(
                originalQuery: cleaned,
                substance: flavorKnowledge.substance,
                otherNames: flavorKnowledge.otherNames,
                technicalEffect: flavorKnowledge.technicalEffect
            )
        }
        
        // Check color mappings
        var searchTerm = cleaned
        if let mappedColorName = colorMappings[lowercased] {
            searchTerm = mappedColorName
        }
        
        // Direct exact match search in embedding records
        for record in embeddingRecords {
            // Check exact match with substance
            if record.substance.lowercased() == searchTerm.lowercased() {
                return AdditiveKnowledge(
                    originalQuery: cleaned,
                    substance: record.substance,
                    otherNames: record.otherNames,
                    technicalEffect: record.technicalEffect
                )
            }
            
            // Check exact match in other names
            let otherNames = record.otherNames.lowercased().components(separatedBy: "|")
            for otherName in otherNames {
                let trimmedOther = otherName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedOther == lowercased {
                    return AdditiveKnowledge(
                        originalQuery: cleaned,
                        substance: record.substance,
                        otherNames: record.otherNames,
                        technicalEffect: record.technicalEffect
                    )
                }
            }
        }
        
        return nil
    }
    
    // Replace the existing searchKnowledge function with this flavor-aware version
    private func searchKnowledge(for additive: String) async -> AdditiveKnowledge? {
        guard !embeddingRecords.isEmpty else { return nil }
        
        print("🔍 Native: Searching for additive: '\(additive)' (threshold: \(matchThreshold))")
        
        // Clean the additive name
        var cleanedAdditive = additive.replacingOccurrences(of: "(preservative)", with: "")
                                      .replacingOccurrences(of: "(", with: "")
                                      .replacingOccurrences(of: ")", with: "")
                                      .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 🍃 NEW: Check for flavor mappings first (highest priority)
        let lowercaseAdditive = cleanedAdditive.lowercased()
        if let flavorKnowledge = flavorMappings[lowercaseAdditive] {
            print("🍃 Native: Found flavor mapping for '\(cleanedAdditive)' -> '\(flavorKnowledge.substance)'")
            // 🆕 UPDATE ORIGINAL QUERY TO MATCH ACTUAL INPUT
            return AdditiveKnowledge(
                originalQuery: cleanedAdditive,
                substance: flavorKnowledge.substance,
                otherNames: flavorKnowledge.otherNames,
                technicalEffect: flavorKnowledge.technicalEffect
            )
        }
        
        // 🎨 Check for color mappings
        if let mappedColorName = colorMappings[lowercaseAdditive] {
            print("🎨 Native: Mapped color '\(cleanedAdditive)' -> '\(mappedColorName)'")
            cleanedAdditive = mappedColorName
        } else {
            // Also check for partial matches with common patterns
            for (pattern, officialName) in colorMappings {
                if lowercaseAdditive.contains(pattern) || pattern.contains(lowercaseAdditive) {
                    print("🎨 Native: Partial color match '\(cleanedAdditive)' -> '\(officialName)'")
                    cleanedAdditive = officialName
                    break
                }
            }
        }
        
        // Continue with normal embedding search for non-flavor additives
        let queryEmbedding = generateQueryEmbedding(for: cleanedAdditive)
        
        var bestMatch: EmbeddingRecord?
        var bestScore: Float = 0.0
        
        for record in embeddingRecords {
            let similarity = cosineSimilarity(queryEmbedding, record.embedding)
            
            let exactMatch = isExactMatch(additive: cleanedAdditive, record: record)
            let partialMatch = isPartialMatch(additive: cleanedAdditive, record: record)
            
            var finalScore = similarity
            if exactMatch {
                finalScore += 0.5
            } else if partialMatch {
                finalScore += 0.3
            }
            
            if finalScore > bestScore {
                bestScore = finalScore
                bestMatch = record
            }
        }
        
        if let match = bestMatch, bestScore >= matchThreshold {
            let confidence = bestScore >= 0.7 ? "High" : (bestScore >= 0.5 ? "Medium" : "Low")
            print("✅ Native: Found match: '\(match.substance)' (score: \(bestScore), confidence: \(confidence))")
            return AdditiveKnowledge(
                originalQuery: cleanedAdditive,
                substance: match.substance,
                otherNames: match.otherNames,
                technicalEffect: match.technicalEffect
            )
        }
        
        if let match = bestMatch {
            print("❌ Native: Rejected low-quality match for '\(additive)': '\(match.substance)' (score: \(bestScore) < threshold: \(matchThreshold))")
        } else {
            print("❌ Native: No matches found for '\(additive)'")
        }
        return nil
    }
    
    // Generate a simple query embedding based on text features
    private func generateQueryEmbedding(for text: String) -> [Float] {
        // Create a simple but effective embedding based on text characteristics
        var embedding = Array(repeating: Float(0.0), count: embeddingDimension)
        
        let cleanText = text.lowercased()
        let words = cleanText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        guard !words.isEmpty else { return embedding }
        
        // Generate features based on text characteristics
        for (wordIndex, word) in words.enumerated() {
            let wordWeight = 1.0 / Float(words.count)
            let positionWeight = 1.0 - (Float(wordIndex) / Float(words.count))
            
            // Character-based features
            for (charIndex, char) in word.enumerated() {
                let ascii = Float(char.asciiValue ?? 0)
                let embeddingIndex = (charIndex + wordIndex * 10) % embeddingDimension
                embedding[embeddingIndex] += sin(ascii * 0.1) * wordWeight * positionWeight
            }
            
            // Word length features
            let length = Float(word.count)
            let lengthIndex = (word.count * 7) % embeddingDimension
            embedding[lengthIndex] += tanh(length / 10.0) * wordWeight
            
            // Chemical pattern features
            let chemicalPatterns = ["acid", "ate", "ine", "ium", "ide", "oxy", "meth", "eth", "prop"]
            for (patternIndex, pattern) in chemicalPatterns.enumerated() {
                if word.contains(pattern) {
                    let patternEmbeddingIndex = (patternIndex * 23 + wordIndex * 5) % embeddingDimension
                    embedding[patternEmbeddingIndex] += 0.5 * wordWeight
                }
            }
        }
        
        // Normalize the embedding
        let magnitude = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if magnitude > 0 {
            embedding = embedding.map { $0 / magnitude }
        }
        
        return embedding
    }
    
    // Compute cosine similarity using Accelerate framework
    private func cosineSimilarity(_ vec1: [Float], _ vec2: [Float]) -> Float {
        guard vec1.count == vec2.count && !vec1.isEmpty else { return 0.0 }
        
        var dotProduct: Float = 0.0
        var magnitude1: Float = 0.0
        var magnitude2: Float = 0.0
        
        // Use Accelerate for efficient computation
        vDSP_dotpr(vec1, 1, vec2, 1, &dotProduct, vDSP_Length(vec1.count))
        vDSP_svesq(vec1, 1, &magnitude1, vDSP_Length(vec1.count))
        vDSP_svesq(vec2, 1, &magnitude2, vDSP_Length(vec2.count))
        
        magnitude1 = sqrt(magnitude1)
        magnitude2 = sqrt(magnitude2)
        
        guard magnitude1 > 0 && magnitude2 > 0 else { return 0.0 }
        
        return dotProduct / (magnitude1 * magnitude2)
    }
    
    // Check for exact matches
    private func isExactMatch(additive: String, record: EmbeddingRecord) -> Bool {
        let additiveClean = additive.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let substanceClean = record.substance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        return additiveClean == substanceClean
    }
    
    // Replace the existing isPartialMatch function with this enhanced version
    private func isPartialMatch(additive: String, record: EmbeddingRecord) -> Bool {
        let additiveClean = additive.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let substanceClean = record.substance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 🔍 NEW: Enhanced partial matching for similar chemical names
        
        // 1. Remove common chemical suffixes/prefixes for comparison
        let additiveNormalized = normalizeChemicalName(additiveClean)
        let substanceNormalized = normalizeChemicalName(substanceClean)
        
        // 2. Check normalized names
        if additiveNormalized == substanceNormalized {
            print("🔍 Native: Normalized match: '\(additiveClean)' ≈ '\(substanceClean)'")
            return true
        }
        
        // 3. Check if one contains the other (original logic)
        if additiveClean.contains(substanceClean) || substanceClean.contains(additiveClean) {
            print("🔍 Native: Contains match: '\(additiveClean)' ↔ '\(substanceClean)'")
            return true
        }
        
        // 4. Check word-by-word overlap for chemical names
        let additiveWords = Set(additiveClean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        let substanceWords = Set(substanceClean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        
        let intersection = additiveWords.intersection(substanceWords)
        let similarity = Double(intersection.count) / Double(max(additiveWords.count, substanceWords.count))
        
        if similarity >= 0.7 && intersection.count >= 2 {
            print("🔍 Native: Word overlap match: '\(additiveClean)' ↔ '\(substanceClean)' (similarity: \(similarity))")
            return true
        }
        
        // 5. Check other names
        let otherNamesList = record.otherNames.lowercased().components(separatedBy: "|")
        for otherName in otherNamesList {
            let otherNameClean = otherName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !otherNameClean.isEmpty {
                if otherNameClean.contains(additiveClean) || additiveClean.contains(otherNameClean) {
                    print("🔍 Native: Other name match: '\(additiveClean)' ↔ '\(otherNameClean)'")
                    return true
                }
                
                // Also check normalized other names
                let otherNameNormalized = normalizeChemicalName(otherNameClean)
                if additiveNormalized == otherNameNormalized {
                    print("🔍 Native: Normalized other name match: '\(additiveClean)' ≈ '\(otherNameClean)'")
                    return true
                }
            }
        }
        
        return false
    }

    // 🔍 NEW: Helper function to normalize chemical names for better matching
    private func normalizeChemicalName(_ name: String) -> String {
        var normalized = name
        
        // Remove numbers and hyphens that might differ between similar chemicals
        normalized = normalized.replacingOccurrences(of: #"-\d+-"#, with: "-", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
        
        // Remove extra spaces and normalize
        normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return normalized
    }
}
// MARK: - Food Record Data Structure
struct FoodRecord {
    let fdcId: String
    let brandOwner: String
    let brandName: String
    let subBrandName: String
    let ingredients: String
    let brandedFoodCategory: String
    let description: String
}
// MARK: - Image Picker
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    let sourceType: UIImagePickerController.SourceType
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        
        print("🎯 ImagePicker: Requested sourceType: \(sourceType)")
        
        // Check if the source type is available
        if UIImagePickerController.isSourceTypeAvailable(sourceType) {
            picker.sourceType = sourceType
            print("🎯 ImagePicker: Using sourceType: \(sourceType)")
        } else {
            // Fallback to photo library if requested source isn't available
            picker.sourceType = .photoLibrary
            print("🎯 ImagePicker: Fallback to photoLibrary (requested source not available)")
        }
        
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
// MARK: - Food Category Classifier

@Observable
@MainActor
class FoodCategoryClassifier {
    private var model: MLModel?
    private var vocab: [String: Int] = [:]
    private var classLabels: [String] = []
    private let maxLength = 256
    
    var isLoaded = false
    var isLoading = false
    var errorMessage: String?
    
    init() {
        Task(priority: .userInitiated) { [weak self] in
            await self?.loadModel()
        }
    }
    
    private func loadModel() async {
        guard !isLoading else { return }
        isLoading = true
        
        do {
            // 🔍 DEBUG: List all files in the bundle
            print("🔍 FoodClassifier: Listing bundle contents...")
            if let bundleURL = Bundle.main.resourceURL {
                let bundleContents = try FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
                print("📁 Bundle contents:")
                for file in bundleContents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    print("  - \(file.lastPathComponent)")
                }
            }
            
            // 🆕 UPDATED: Try different possible names AND extensions for the model
            let possibleNames = ["FoodClassifier", "foodclassifier", "FoodCategoryClassifier"]
            let possibleExtensions = ["mlmodelc", "mlpackage", "mlmodel"]  // 🆕 ADDED .mlmodelc
            var modelURL: URL?
            
            for name in possibleNames {
                for ext in possibleExtensions {
                    if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                        modelURL = url
                        print("✅ FoodClassifier: Found model at: \(name).\(ext)")
                        break
                    }
                }
                if modelURL != nil { break }
            }
            
            guard let finalModelURL = modelURL else {
                throw ClassifierError.modelNotFound("No FoodClassifier model found in bundle. Check target membership.")
            }
            
            model = try MLModel(contentsOf: finalModelURL)
            
            // Load tokenizer configuration
            guard let configPath = Bundle.main.path(forResource: "tokenizer_config", ofType: "json") else {
                throw ClassifierError.configNotFound("tokenizer_config.json not found in bundle")
            }

            let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]

            guard let vocabDict = config["vocab"] as? [String: Int],
                  let labels = config["class_labels"] as? [String] else {
                throw ClassifierError.configNotFound("tokenizer_config.json has invalid format")
            }
            
            vocab = vocabDict
            classLabels = labels
            isLoaded = true
            errorMessage = nil
            
            print("✅ FoodCategoryClassifier: Loaded successfully with \(classLabels.count) categories")
            
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
            print("❌ FoodCategoryClassifier: \(error)")
        }
        
        isLoading = false
    }
    
    func classifyFood(ingredients: String) async -> [ClassificationResult]? {
        guard isLoaded, let model = model else { return nil }
        
        do {
            // 🆕 IMPROVED: Match training preprocessing exactly
            let preprocessedText = ingredients.lowercased()
            
            // 🆕 IMPROVED: Better tokenization
            let tokens = tokenize(text: preprocessedText)
            let inputIds = convertToIds(tokens: tokens)
            
            // 🆕 IMPROVED: Proper padding and attention mask
            let paddedInputIds: [Int]
            let attentionMask: [Int]
            
            if inputIds.count >= maxLength {
                // Truncate if too long
                paddedInputIds = Array(inputIds.prefix(maxLength))
                attentionMask = Array(repeating: 1, count: maxLength)
            } else {
                // Pad if too short
                paddedInputIds = inputIds + Array(repeating: 0, count: maxLength - inputIds.count)
                attentionMask = Array(repeating: 1, count: inputIds.count) + Array(repeating: 0, count: maxLength - inputIds.count)
            }
            
            // 🆕 DEBUG: Add logging to see what's happening
            print("🔍 FoodClassifier Debug:")
            print("  Original: '\(ingredients)'")
            print("  Preprocessed: '\(preprocessedText)'")
            print("  Tokens (first 10): \(Array(tokens.prefix(10)))")
            print("  Input IDs (first 10): \(Array(paddedInputIds.prefix(10)))")
            print("  Attention mask sum: \(attentionMask.reduce(0, +))/\(maxLength)")
            
            // Check for unknown tokens
            let unknownTokens = tokens.filter { vocab[$0] == nil }
            if !unknownTokens.isEmpty {
                print("  ⚠️ Unknown tokens: \(unknownTokens.prefix(5))")
            }
            
            // Create MLMultiArray inputs
            let inputIdsArray = try MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32)
            let attentionMaskArray = try MLMultiArray(shape: [1, NSNumber(value: maxLength)], dataType: .int32)
            
            for i in 0..<maxLength {
                inputIdsArray[i] = NSNumber(value: paddedInputIds[i])
                attentionMaskArray[i] = NSNumber(value: attentionMask[i])
            }
            
            // Make prediction
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputIdsArray),
                "attention_mask": MLFeatureValue(multiArray: attentionMaskArray)
            ])
            
            let output = try await model.prediction(from: input)
            
            // Process output
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                throw ClassifierError.predictionFailed("No logits output")
            }
            
            // 🆕 DEBUG: Log raw logits
            let rawLogits = (0..<min(5, classLabels.count)).map { logits[$0].doubleValue }
            print("  Raw logits (first 5): \(rawLogits)")
            
            // Convert logits to softmax probabilities and get top 3
            var categoryScores: [(category: String, score: Double)] = []
            
            for i in 0..<classLabels.count {
                let score = logits[i].doubleValue
                categoryScores.append((category: classLabels[i], score: score))
            }
            
            // Apply softmax to convert to probabilities
            let maxScore = categoryScores.map { $0.score }.max() ?? 0
            let expScores = categoryScores.map { exp($0.score - maxScore) }
            let sumExpScores = expScores.reduce(0, +)
            
            let probabilities = expScores.map { $0 / sumExpScores }
            
            // Create results with probabilities
            var results: [ClassificationResult] = []
            for i in 0..<categoryScores.count {
                results.append(ClassificationResult(
                    category: categoryScores[i].category,
                    confidence: probabilities[i]
                ))
            }
            
            // Sort by confidence and return top 3
            let topResults = Array(results.sorted { $0.confidence > $1.confidence }.prefix(3))
            
            // 🆕 DEBUG: Log results
            print("  Top 3 predictions:")
            for (i, result) in topResults.enumerated() {
                print("    \(i+1). \(result.category): \(String(format: "%.3f", result.confidence))")
            }
            
            return topResults
            
        } catch {
            print("❌ Classification error: \(error)")
            return nil
        }
    }
    
    private func tokenize(text: String) -> [String] {
        // 1. Convert to lowercase (match training)
        let lowercased = text.lowercased()
        
        // 2. Add DistilBERT special tokens
        let textWithSpecialTokens = "[CLS] \(lowercased) [SEP]"
        
        // 3. Improved tokenization that's closer to DistilBERT
        var tokens: [String] = []
        
        // Split by spaces first
        let words = textWithSpecialTokens.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        for word in words {
            // Handle special tokens
            if word == "[CLS]" || word == "[SEP]" {
                tokens.append(word)
                continue
            }
            
            // Handle punctuation more carefully
            var currentWord = ""
            for char in word {
                if char.isLetter || char.isNumber {
                    currentWord.append(char)
                } else {
                    // Add accumulated word if not empty
                    if !currentWord.isEmpty {
                        tokens.append(currentWord)
                        currentWord = ""
                    }
                    // Add punctuation as separate token if it's significant
                    let punctuation = String(char)
                    if punctuation == "," || punctuation == "(" || punctuation == ")" {
                        tokens.append(punctuation)
                    }
                }
            }
            
            // Add final accumulated word
            if !currentWord.isEmpty {
                tokens.append(currentWord)
            }
        }
        
        return tokens
    }
    
    private func convertToIds(tokens: [String]) -> [Int] {
        return tokens.map { token in
            if let id = vocab[token] {
                return id
            } else {
                // Use the actual UNK token ID from the config
                return vocab["[UNK]"] ?? vocab["<unk>"] ?? 100
            }
        }
    }
    
    // 🆕 NEW: Add debugging function
    func debugTokenization(text: String) {
        print("\n=== TOKENIZATION DEBUG ===")
        print("Input: '\(text)'")
        
        let preprocessed = text.lowercased()
        print("Preprocessed: '\(preprocessed)'")
        
        let tokens = tokenize(text: preprocessed)
        print("Tokens (\(tokens.count)): \(tokens)")
        
        let inputIds = convertToIds(tokens: tokens)
        print("Input IDs: \(inputIds)")
        
        // Check vocabulary coverage
        let unknownTokens = tokens.filter { vocab[$0] == nil }
        let knownTokens = tokens.filter { vocab[$0] != nil }
        
        print("Known tokens (\(knownTokens.count)): \(knownTokens)")
        if !unknownTokens.isEmpty {
            print("⚠️ Unknown tokens (\(unknownTokens.count)): \(unknownTokens)")
        }
        
        print("Vocabulary size: \(vocab.count)")
        print("Class labels: \(classLabels.count)")
        print("=========================\n")
    }
}

enum ClassifierError: Error, LocalizedError {
    case modelNotFound(String)
    case configNotFound(String)
    case predictionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound(let message): return message
        case .configNotFound(let message): return message
        case .predictionFailed(let message): return message
        }
    }
}
// MARK: - Classification Result
struct ClassificationResult {
    let category: String
    let confidence: Double
}
extension Color {
    static let appBackground = Color("AppBackground")
    static let cardBackground = Color("CardBackground")
    static let primaryAccent = Color("PrimaryAccent")
    static let secondaryAccent = Color("SecondaryAccent")
    
    // Fallback colors if not defined in Assets
    static let lightBackground = Color(UIColor.systemGray6)
    static let lightCardBackground = Color.white
    static let darkBackground = Color(hex: "#1C1C1E")
    static let darkCardBackground = Color(hex: "#2C2C2E")
}
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
// MARK: - About View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    private var acknowledgmentSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Acknowledgments", systemImage: "heart.fill")
                .font(.headline)
                .foregroundColor(.red)
            
            Text("This app used the following resources:")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // FDA Acknowledgment (logo removed, text kept)
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.2))
                    .frame(height: 120)
                    .overlay(
                        Text("FDA")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                    )
                
                VStack(alignment: .center, spacing: 8) {
                    Text("U.S. Food & Drug Administration")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    
                    Text("Authoritative information on food additives, including technical effects and CFR regulations, sourced from the FDA Substances Added to Food inventory.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }
            .padding()
            .background(Color.blue.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            )
            
            // USDA Acknowledgment (logo removed, text updated)
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.green.opacity(0.2))
                    .frame(height: 120)
                    .overlay(
                        Text("USDA")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    )
                
                VStack(alignment: .center, spacing: 8) {
                    Text("U.S. Department of Agriculture")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    
                    Text("Food category classifier training data and random sample entries are sourced from U.S. Department of Agriculture, Agricultural Research Service, Beltsville Human Nutrition Research Center. FoodData Central Global Branded Food Products Database (GBFPD). Available from https://fdc.nal.usda.gov/.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }
            .padding()
            .background(Color.green.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.green.opacity(0.2), lineWidth: 1)
            )
            
            // IAFNS Acknowledgment (logo kept, text updated)
            VStack(spacing: 16) {
                if let iafnsImage = UIImage(named: "iafns icon") {
                    Image(uiImage: iafnsImage)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange.opacity(0.2))
                        .frame(height: 120)
                        .overlay(
                            Text("IAFNS")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                        )
                }
                
                VStack(alignment: .center, spacing: 8) {
                    Text("Funding and Support")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    
                    Text("This project was partially funded by the Institute for the Advancement of Food and Nutrition Sciences (IAFNS). The contents and functionality of this mobile web app, including any data presented, are solely the responsibility of the developer and do not necessarily reflect the views of IAFNS. IAFNS make no warranties and assume no liability for any errors or omissions in the information provided.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                
                
            }
            .padding()
            .background(Color.orange.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
            )
            
            // Data Currency Information
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 120)
                    .overlay(
                        Text("Data")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.gray)
                    )
                
                VStack(alignment: .center, spacing: 8) {
                    Text("Database Information")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• Branded Food Database: Last updated 04/24/2025")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("• Substances Added to Food Inventory: Last updated 02/13/2025")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            
            
        }
        .padding()
        .background(Color.white)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // NEW: Usage Instructions Section (added at the top)
                    VStack(alignment: .leading, spacing: 16) {
                        Label("How to Use This App", systemImage: "list.number")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                        
                        Text("Follow these simple steps to analyze your food ingredients:")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 8)
                        
                        // Step 1: Input Ingredients
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 40, height: 40)
                                    Text("1")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Input Your Ingredient List")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                    
                                    Text("Choose one of these options:")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "camera.fill")
                                            .foregroundColor(.orange)
                                            .font(.system(size: 16))
                                        Text("**Scan Ingredients:** Take a photo of the ingredient list on food packaging")
                                            .font(.subheadline)
                                    }
                                    .padding(.horizontal, 16)
                                
                                // Important note about ingredient list vs barcode
                                HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundColor(.red)
                                                .font(.system(size: 14))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("**Important:** Photograph the ingredient list text, NOT the barcode")
                                                    .font(.caption)
                                                    .foregroundColor(.red)
                                                    .fontWeight(.medium)
                                                Text("Look for small text that lists ingredients like \"flour, water, salt...\"")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.red.opacity(0.1))
                                        .cornerRadius(8)
                                
                                // Other options
                                HStack(spacing: 8) {
                                    Image(systemName: "dice.fill")
                                        .foregroundColor(.blue)
                                        .font(.system(size: 16))
                                    Text("**Random Sample:** Try a sample from our database")
                                        .font(.subheadline)
                                }
                                .padding(.horizontal, 16)
                                
                                HStack(spacing: 8) {
                                    Image(systemName: "keyboard.fill")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 16))
                                    Text("**Manual Entry:** Type or paste ingredient list directly")
                                        .font(.subheadline)
                                }
                                .padding(.horizontal, 16)
                            }
                            .padding(.leading, 20)
                        }
                        
                        // Step 2: Classify Food Category
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 40, height: 40)
                                    Text("2")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Classify Food Category")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                    
                                    Text("Help the AI provide more relevant explanations")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "tag.fill")
                                        .foregroundColor(.orange)
                                        .font(.system(size: 16))
                                    Text("Tap **\"Classify Food Category\"** to identify the type of food")
                                        .font(.subheadline)
                                }
                                
                                HStack(spacing: 8) {
                                    Image(systemName: "hand.tap.fill")
                                        .foregroundColor(.orange)
                                        .font(.system(size: 16))
                                    Text("Select the most appropriate category from the AI suggestions")
                                        .font(.subheadline)
                                }
                            }
                            .padding(.leading, 32)
                        }
                        
                        // Step 3: Analyze Additives
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 40, height: 40)
                                    Text("3")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Identify & Analyze Additives")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                    
                                    Text("Get detailed information about food additives")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass.circle.fill")
                                        .foregroundColor(.blue)
                                        .font(.system(size: 16))
                                    Text("Tap **\"Identify & Analyze Additives\"** to start the AI analysis")
                                        .font(.subheadline)
                                }
                                
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .foregroundColor(.blue)
                                        .font(.system(size: 16))
                                    Text("View detailed knowledge about each additive found")
                                        .font(.subheadline)
                                }
                                
                                HStack(spacing: 8) {
                                    Image(systemName: "text.bubble.fill")
                                        .foregroundColor(.purple)
                                        .font(.system(size: 16))
                                    Text("Get user-friendly explanations in plain English")
                                        .font(.subheadline)
                                }
                            }
                            .padding(.leading, 32)
                        }
                        
                        // Quick Tips
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundColor(.yellow)
                                Text("Quick Tips")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("• For best photo scanning results, ensure good lighting and clear text")
                                Text("• Use the Random Sample feature to explore different food products")
                                Text("• Save your results to History for future reference")
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.leading, 8)
                        }
                        .padding()
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Label("How Our App Works", systemImage: "gearshape.2.fill")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("Our app uses advanced AI technology combined with a comprehensive food additive database to analyze ingredient lists and provide detailed information about food additives.")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(12)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Technology Behind the App", systemImage: "cpu.fill")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        if let uiImage = UIImage(named: "rag_llm_workflow") {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .cornerRadius(12)
                                .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
                        } else {
                            // Fallback: Show placeholder if image not found
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 200)
                                .overlay(
                                    VStack {
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                            .foregroundColor(.gray)
                                        Text("RAG + LLM Workflow")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                )
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Our 3-Step Process:")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "1.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Knowledge Search")
                                        .fontWeight(.medium)
                                    Text("Search our database of food additives")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "2.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("AI Analysis")
                                        .fontWeight(.medium)
                                    Text("LLM processes ingredients and knowledge")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "3.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("User-Friendly Response")
                                        .fontWeight(.medium)
                                    Text("Generate easy-to-understand explanations")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Common Food Additive Types", systemImage: "list.bullet.rectangle.fill")
                            .font(.headline)
                            .foregroundColor(.green)
                        
                        if let uiImage = UIImage(named: "food_additives_categories") {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .cornerRadius(12)
                                .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
                        } else {
                            // Fallback: Show placeholder if image not found
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 200)
                                .overlay(
                                    VStack {
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                            .foregroundColor(.gray)
                                        Text("Food Additive Categories")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                )
                        }
                        
                        Text("Food additives serve various purposes in modern food products, from enhancing flavor and appearance to extending shelf life and improving texture.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                    
                    acknowledgmentSection
                }
                .padding()
            }
            .background(Color(hex: "#F5F7FA"))
            .navigationTitle("About This App")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }
}
// MARK: - Device Detection Utilities

extension UIDevice {
    static func getDeviceIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
    
    static func getDeviceModelName() -> String {
        let identifier = getDeviceIdentifier()
        
        // Check for Mac first
        if identifier.contains("Mac") {
            return "Mac (Designed for iPhone)"
        }
        // Mac (Designed for iPhone) uses this string
        if identifier.contains("iPad8,6") {
            return "Mac (Designed for iPhone)"
        }
        
        // iPhone model mapping for known models
        switch identifier {
        // iPhone 13 series
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        
        // iPhone SE 3rd Gen
        case "iPhone14,6": return "iPhone SE (3rd generation)"
        
        // iPhone 14 series
        case "iPhone14,7": return "iPhone 14"
        case "iPhone14,8": return "iPhone 14 Plus"
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        
        // iPhone 15 series
        case "iPhone15,4": return "iPhone 15"
        case "iPhone15,5": return "iPhone 15 Plus"
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        
        // iPhone 16 series
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"
        case "iPhone17,5": return "iPhone 16e"
        
        default:
            // For unknown future iPhone models, show the identifier as-is
            if identifier.hasPrefix("iPhone") {
                return identifier
            }
            return "Unknown Device (\(identifier))"
        }
    }
    
    static func supportsMLX() -> Bool {
        let identifier = getDeviceIdentifier()
        
        // Mac (designed for iPhone) supports MLX
        if identifier.contains("Mac") {
            return true
        }
        if identifier.contains("iPad8,6") {
            return true
        }
        // Check if iPhone model is >= iPhone14,7 (iPhone 14 or newer)
        if identifier.hasPrefix("iPhone") {
            // Extract major and minor version numbers
            let versionString = identifier.replacingOccurrences(of: "iPhone", with: "")
            let components = versionString.components(separatedBy: ",")
            
            guard components.count >= 2,
                  let major = Int(components[0]),
                  let minor = Int(components[1]) else {
                return false // Can't parse version, assume unsupported
            }
            
            // iPhone 14,7 or greater supports MLX
            if major > 14 {
                return true  // iPhone 15,x, iPhone 16,x, etc.
            } else if major == 14 {
                return minor >= 7  // iPhone 14,7 (iPhone 14) or higher
            } else {
                return false  // iPhone 13,x or older
            }
        }
        
        // Default to false for safety if we can't determine the model
        return false
    }
    
    static func isRunningOnMac() -> Bool {
        return getDeviceIdentifier().contains("Mac")
    }
}
// MARK: - CFR (Code of Federal Regulations) Manager

@Observable
@MainActor
class CFRManager {
    
    struct CFRData {
        let substance: String
        let cfrCodes: [String]
    }
    
    private var cfrLookup: [String: [String]] = [:] // substance -> cfr codes
    var isLoaded = false
    var isLoading = false
    
    init() {
        Task(priority: .userInitiated) { [weak self] in
            await self?.loadCFRData()
        }
    }
    
    private func loadCFRData() async {
        guard !isLoaded && !isLoading else { return }
        isLoading = true
        
        print("🔄 CFR: Loading CFR data from CSV...")
        
        do {
            guard let path = Bundle.main.path(forResource: "FoodSubstancesCFR", ofType: "csv") else {
                print("❌ CFR: FoodSubstancesCFR.csv not found in bundle")
                isLoading = false
                return
            }
            
            // Read file with proper encoding
            let content: String
            do {
                content = try String(contentsOfFile: path, encoding: .windowsCP1252)
            } catch {
                content = try String(contentsOfFile: path, encoding: .utf8)
            }
            
            let lines = content.components(separatedBy: .newlines)
            
            // Header is always at line 9 (index 8)
            let headerRowIndex = 8
            guard headerRowIndex < lines.count else {
                print("❌ CFR: CSV file has fewer than 9 lines")
                isLoading = false
                return
            }
            
            let headers = parseCSVLine(lines[headerRowIndex])
            
            guard let substanceIndex = headers.firstIndex(of: "Substance") else {
                print("❌ CFR: Substance column not found in header")
                isLoading = false
                return
            }
            
            // Find CFR code columns (Reg add01 to Reg add20)
            var cfrColumnIndices: [Int] = []
            for i in 0..<headers.count {
                let header = headers[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if header.hasPrefix("Reg add") || header.hasPrefix("Regadd") {
                    cfrColumnIndices.append(i)
                }
            }
            
            var substancesWithCodes = 0
            
            // Process data rows (starting from line 10, index 9)
            for lineIndex in (headerRowIndex + 1)..<lines.count {
                let line = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                
                let columns = parseCSVLine(line)
                guard columns.count > substanceIndex else { continue }
                
                let substance = columns[substanceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if substance.isEmpty { continue }
                
                // Collect CFR codes from all CFR columns
                var cfrCodes: [String] = []
                for columnIndex in cfrColumnIndices {
                    if columnIndex < columns.count {
                        let code = columns[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !code.isEmpty && code != "0" && code.lowercased() != "n/a" {
                            cfrCodes.append(code)
                        }
                    }
                }
                
                if !cfrCodes.isEmpty {
                    cfrLookup[substance.uppercased()] = cfrCodes
                    substancesWithCodes += 1
                }
            }
            
            isLoaded = true
            print("✅ CFR: Loaded CFR data for \(substancesWithCodes) substances")
            
        } catch {
            print("❌ CFR: Failed to load CFR data: \(error)")
        }
        
        isLoading = false
    }
    
    private func parseCSVLine(_ line: String) -> [String] {
        var columns: [String] = []
        var currentColumn = ""
        var insideQuotes = false
        var i = line.startIndex
        
        while i < line.endIndex {
            let char = line[i]
            
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == "," && !insideQuotes {
                columns.append(currentColumn)
                currentColumn = ""
            } else {
                currentColumn.append(char)
            }
            
            i = line.index(after: i)
        }
        
        // Add the last column
        columns.append(currentColumn)
        
        // Clean up quotes from columns
        return columns.map { column in
            var cleaned = column.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
                cleaned = String(cleaned.dropFirst().dropLast())
            }
            return cleaned
        }
    }
    private func isBasicIngredientForCFR(_ substance: String) -> Bool {
        let cleaned = substance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        let basicIngredients: Set<String> = [
            "sugar", "cane sugar", "brown sugar", "white sugar", "granulated sugar",
            "flour", "wheat flour", "water", "salt", "oil", "milk", "eggs", "butter",
            "honey", "molasses", "corn syrup", "rice", "oats", "barley"
        ]
        
        return basicIngredients.contains(cleaned)
    }

    private func isRelevantMatch(searchTerm: String, foundKey: String) -> Bool {
        if searchTerm.count < 4 {
            return false
        }
        
        // Ensure there's substantial overlap
        let overlap = min(searchTerm.count, foundKey.count)
        let longerTerm = max(searchTerm.count, foundKey.count)
        
        // Require at least 60% overlap for the match to be considered relevant
        return Double(overlap) / Double(longerTerm) >= 0.6
    }
    
    func getCFRCodes(for substance: String) -> [String] {
        guard isLoaded else { return [] }
        
        let uppercaseSubstance = substance.uppercased()
        let lowercaseSubstance = substance.lowercased()
        
        let specialCases: [String: [String]] = [
            // Artificial flavors - General Food Additives section
            "artificial flavor": ["170.3"],
            "artificial flavors": ["170.3"],
            "natural flavor": ["170.3"],
            "natural flavors": ["170.3"],
            "natural and artificial flavor": ["170.3"],
            "natural and artificial flavors": ["170.3"],
            
            // Other common additives that might need general links
            "artificial colors": ["170.3"],
            "artificial color": ["170.3"],
            "natural colors": ["170.3"],
            "natural color": ["170.3"],
            
            // Preservatives general category
            "preservatives": ["170.3"],
            "preservative": ["170.3"]
        ]
        
        // Check special cases first
        if let specialCodes = specialCases[lowercaseSubstance] {
            print("🎯 CFR: Found special case for '\(substance)' -> \(specialCodes)")
            return specialCodes
        }
        
        // Also check for partial matches in special cases
        for (key, codes) in specialCases {
            if lowercaseSubstance.contains(key) || key.contains(lowercaseSubstance) {
                print("🎯 CFR: Found partial special case match for '\(substance)' -> \(codes)")
                return codes
            }
        }
        
        if isBasicIngredientForCFR(substance) {
            print("🚫 CFR: Skipping basic ingredient: '\(substance)'")
            return []
        }
        
        // Direct lookup
        if let codes = cfrLookup[uppercaseSubstance] {
            return codes
        }
        
        // Try partial matches for chemical names
        for (key, codes) in cfrLookup {
            if key.contains(uppercaseSubstance) || uppercaseSubstance.contains(key) {
                if isRelevantMatch(searchTerm: uppercaseSubstance, foundKey: key) {
                    return codes
                }
            }
        }
        
        return []
    }
    
    func generateCFRURLs(for codes: [String]) -> [(code: String, url: URL)] {
        var results: [(code: String, url: URL)] = []
        
        for rawCode in codes {
            // Clean the CFR code
            let cleanedCode = rawCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "=T(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "T(", with: "")
            
            if cleanedCode == "170.3" {
                // General Food Additives section
                let urlString = "https://www.ecfr.gov/current/title-21/chapter-I/subchapter-B/part-170"
                if let url = URL(string: urlString) {
                    results.append((code: "170", url: url))
                }
                continue
            }
            
            let components = cleanedCode.components(separatedBy: ".")
            guard components.count >= 2,
                  let part = components.first,
                  !part.isEmpty,
                  let _ = Int(part) else {
                print("⚠️ CFR: Skipping invalid code format: '\(rawCode)' -> '\(cleanedCode)'")
                continue
            }
            
            // Always use subchapter-B and subpart-C
            let urlString = "https://www.ecfr.gov/current/title-21/chapter-I/subchapter-B/part-\(part)/subpart-C/section-\(cleanedCode)"
            
            if let url = URL(string: urlString) {
                results.append((code: cleanedCode, url: url))
            } else {
                print("⚠️ CFR: Failed to create URL for code: '\(cleanedCode)'")
            }
        }
        
        return results
    }
}

