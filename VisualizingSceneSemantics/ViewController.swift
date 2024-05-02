import RealityKit
import ARKit
import AVFoundation

class ViewController: UIViewController, ARSessionDelegate, SCNSceneRendererDelegate {
    
    @IBOutlet var arView: ARView!
    
    var distanceUpdateTimer: Timer?
    var speechTimer: Timer?
    
    var hapticGenerator: UIImpactFeedbackGenerator?
    let speechSynthesizer = AVSpeechSynthesizer()
    
    let coachingOverlay = ARCoachingOverlayView()
    
    
    // Cache for 3D text geometries representing the classification values.
    var modelsForClassification: [ARMeshClassification: ModelEntity] = [:]

    /// - Tag: ViewDidLoad
    override func viewDidLoad() {
        super.viewDidLoad()
        //arView.delegate = self
        
        distanceUpdateTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(updateDistance), userInfo: nil, repeats: true)
        // Initialize haptic generator
        hapticGenerator = UIImpactFeedbackGenerator(style: .heavy)
                hapticGenerator?.prepare()
        
        arView.session.delegate = self
        
        setupCoachingOverlay()

        arView.environment.sceneUnderstanding.options = []
        
        // Turn on occlusion from the scene reconstruction's mesh.
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
        
        // Turn on physics for the scene reconstruction's mesh.
        arView.environment.sceneUnderstanding.options.insert(.physics)

        // Display a debug visualization of the mesh.
        arView.debugOptions.insert(.showSceneUnderstanding)
        
        // For performance, disable render options that are not required for this app.
        arView.renderOptions = [.disablePersonOcclusion, .disableDepthOfField, .disableMotionBlur]
        
        // Manually configure what kind of AR session to run since
        // ARView on its own does not turn on mesh classification.
        arView.automaticallyConfigureSession = false
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification

        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tapRecognizer)
        
    }
    
    @objc func updateDistance() {
//        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
//        if let result = arView.raycast(from: screenCenter, allowing:.estimatedPlane, alignment:.any).first {
//            let distance = distance(result.worldTransform.position, arView.cameraTransform.translation)
//            print("Distance: \(distance)")
        
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            if let result = arView.raycast(from: screenCenter, allowing:.estimatedPlane, alignment:.any).first {
                let cameraTransform = arView.session.currentFrame?.camera.transform
                let cameraPosition = SCNVector3(cameraTransform!.columns.3.x, cameraTransform!.columns.3.y, cameraTransform!.columns.3.z)
                let hitTransform = result.worldTransform
                let hitPosition = SCNVector3(hitTransform.columns.3.x, hitTransform.columns.3.y, hitTransform.columns.3.z)
                let distance = calculateDistance(cameraPosition, hitPosition)
                print("Distance: \(distance)")
            provideHapticFeedback(Float(distance))
            
            
            
            
            
                
                // Call nearbyFaceWithClassification
                nearbyFaceWithClassification(to: result.worldTransform.position) { centerOfFace, classification in
                    if let classification = classification {
                        print("Classification: \(classification.description)")
                        let speechUtterance = AVSpeechUtterance(string: classification.description)
                                speechUtterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                                self.speechSynthesizer.speak(speechUtterance)
                    }
                }
            }
    }
    func calculateDistance(_ point1: SCNVector3, _ point2: SCNVector3) -> Float {
        let dx = point2.x - point1.x
        let dy = point2.y - point1.y
        let dz = point2.z - point1.z
        return sqrt(dx*dx + dy*dy + dz*dz)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Prevent the screen from being dimmed to avoid interrupting the AR experience.
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    /// Places virtual-text of the classification at the touch-location's real-world intersection with a mesh.
    /// Note - because classification of the tapped-mesh is retrieved asynchronously, we visualize the intersection
    /// point immediately to give instant visual feedback of the tap.
    @objc
    func handleTap(_ sender: UITapGestureRecognizer) {
        // ...
   }
    

    
    func nearbyFaceWithClassification(to location: SIMD3<Float>, completionBlock: @escaping (SIMD3<Float>?, ARMeshClassification?) -> Void) {
        guard let frame = arView.session.currentFrame else {
            completionBlock(nil, nil)
            return
        }
    
        var meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor })
        
        // Sort the mesh anchors by distance to the given location and filter out
        // any anchors that are too far away (4 meters is a safe upper limit).
        let cutoffDistance: Float = 4.0
        meshAnchors.removeAll { distance($0.transform.position, location) > cutoffDistance }
        meshAnchors.sort { distance($0.transform.position, location) < distance($1.transform.position, location) }

        // Perform the search asynchronously in order not to stall rendering.
        DispatchQueue.global().async {
            for anchor in meshAnchors {
                for index in 0..<anchor.geometry.faces.count {
                    // Get the center of the face so that we can compare it to the given location.
                    let geometricCenterOfFace = anchor.geometry.centerOf(faceWithIndex: index)
                    
                    // Convert the face's center to world coordinates.
                    var centerLocalTransform = matrix_identity_float4x4
                    centerLocalTransform.columns.3 = SIMD4<Float>(geometricCenterOfFace.0, geometricCenterOfFace.1, geometricCenterOfFace.2, 1)
                    let centerWorldPosition = (anchor.transform * centerLocalTransform).position
                     
                    // We're interested in a classification that is sufficiently close to the given location––within 5 cm.
                    let distanceToFace = distance(centerWorldPosition, location)
                    if distanceToFace <= 0.05 {
                        // Get the semantic classification of the face and finish the search.
                        let classification: ARMeshClassification = anchor.geometry.classificationOf(faceWithIndex: index)
                        completionBlock(centerWorldPosition, classification)
                        return
                    }
                }
            }
            
            // Let the completion block know that no result was found.
            completionBlock(nil, nil)
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        guard error is ARError else { return }
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        DispatchQueue.main.async {
            //Present an alert informing about the error that has occurred.
            let alertController = UIAlertController(title: "The AR session failed.", message: errorMessage, preferredStyle: .alert)
//            let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
//                alertController.dismiss(animated: true, completion: nil)
//                self.resetButtonPressed(self)
//            }
//            alertController.addAction(restartAction)
//            self.present(alertController, animated: true, completion: nil)
        }
    }
        
    func model(for classification: ARMeshClassification) -> ModelEntity {
        // Return cached model if available
        if let model = modelsForClassification[classification] {
            model.transform = .identity
            return model.clone(recursive: true)
        }
        
        // Generate 3D text for the classification
        let lineHeight: CGFloat = 0.05
        let font = MeshResource.Font.systemFont(ofSize: lineHeight)
        let textMesh = MeshResource.generateText(classification.description, extrusionDepth: Float(lineHeight * 0.1), font: font)
        let textMaterial = SimpleMaterial(color: classification.color, isMetallic: true)
        let model = ModelEntity(mesh: textMesh, materials: [textMaterial])
        // Move text geometry to the left so that its local origin is in the center
        model.position.x -= model.visualBounds(relativeTo: nil).extents.x / 2
        // Add model to cache
        modelsForClassification[classification] = model
        return model
    }
    
    func sphere(radius: Float, color: UIColor) -> ModelEntity {
        let sphere = ModelEntity(mesh: .generateSphere(radius: radius), materials: [SimpleMaterial(color: color, isMetallic: false)])
        // Move sphere up by half its diameter so that it does not intersect with the mesh
        sphere.position.y = radius
        return sphere
    }
    
    func provideHapticFeedback(_ distance: Float) {
        // Reverse the intensity: stronger haptic for shorter distances
        let intensity = CGFloat(max(0, min(1, 1 - distance / 1.5))) // Example: Inverted distance mapped to intensity between 0 and 1
        hapticGenerator?.impactOccurred(intensity: intensity)
        
    }
}
