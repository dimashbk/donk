import Donk
import SwiftUI

struct InspectorDemoView: View {
    init() {
        InspectorDemoSupport.prepare()
    }

    var body: some View {
        InspectorPlaygroundScreen()
    }
}
