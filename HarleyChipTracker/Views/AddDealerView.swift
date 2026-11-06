import SwiftData
import SwiftUI

/// Add a location that isn't in the bundled list.
struct AddDealerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var address = ""
    @State private var city = ""
    @State private var region = ""
    @State private var country = "US"
    @State private var alreadyCollected = false

    private var canSave: Bool {
        !name.trimmed.isEmpty && !city.trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Store name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Street address (optional)", text: $address)
                        .textInputAutocapitalization(.words)
                    TextField("City", text: $city)
                        .textInputAutocapitalization(.words)
                    TextField(country == "CA" ? "Province (e.g. ON)" : "State (e.g. WI)", text: $region)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Country", selection: $country) {
                        Text("United States").tag("US")
                        Text("Canada").tag("CA")
                        Text("Other").tag("ZZ")
                    }
                } footer: {
                    Text("Add a new dealer, one that has closed, or a shop outside North America. It counts toward your collection like any other store.")
                }

                Section {
                    Toggle("I already have this chip", isOn: $alreadyCollected)
                }
            }
            .navigationTitle("Add Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let store = CustomDealer(
            name: name.trimmed,
            address: address.trimmed,
            city: city.trimmed,
            region: region.trimmed.uppercased(),
            country: country
        )
        context.insert(store)
        if alreadyCollected {
            context.setCollected(true, dealerID: store.dealerID)
        }
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#Preview {
    AddDealerView()
        .modelContainer(.preview)
}
