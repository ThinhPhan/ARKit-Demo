//
//  ViewController.swift
//  demo-arkit
//
//  Created by Thinh Phan on 6/13/19.
//  Copyright © 2019 Thinh Phan. All rights reserved.
//

import UIKit
import SceneKit
import ARKit

class ViewController: UIViewController, ARSCNViewDelegate {
    
    // MARK: - IBOutlet
    
    @IBOutlet var sceneView: ARSCNView!
    
    /// The view controller that displays the status and "restart experience" UI.
    lazy var statusViewController: StatusViewController = {
        return children.lazy.compactMap({ $0 as? StatusViewController }).first!
    }()
    
    // MARK: - Properties
    
    /// A serial queue for thread safety when modifying the SceneKit node graph
    let updateQueue = DispatchQueue(label: Bundle.main.bundleIdentifier! + ".serialSceneKitQueue")
    
    /// Convenience accessor for the session owned by ARSCNView
    var session: ARSession {
        return sceneView.session
    }
    
    // NOTE: The imageConfiguration is better for tracking images,
    // but it has less features,
    // for example it does not have the plane detection.
    let defaultConfiguration: ARWorldTrackingConfiguration = {
        
        guard let images = ARReferenceImage.referenceImages(inGroupNamed: "AR Resources", bundle: nil) else {
            fatalError("Missing expected asset catalog resources.")
        }
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()
        
        configuration.planeDetection = [.vertical, .horizontal]
        configuration.detectionImages = images
        configuration.maximumNumberOfTrackedImages = 1
        return configuration
    }()
    
    let imageConfiguration: ARImageTrackingConfiguration = {
        
        guard let images = ARReferenceImage.referenceImages(inGroupNamed: "AR Resources", bundle: Bundle.main) else {
            fatalError("Missing expected asset catalog resources.")
        }
        
        // Create a session configuration
        let configuration = ARImageTrackingConfiguration()
        
        configuration.trackingImages = images
        configuration.maximumNumberOfTrackedImages = 3
        
        return configuration
    }()
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view's delegate
        sceneView.delegate = self
        sceneView.session.delegate = self
        
        // Show statistics such as fps and timing information
        sceneView.showsStatistics = true
//        sceneView.debugOptions = [.showFeaturePoints, .showWorldOrigin]
        
        // Enable environment-bases lightning
        sceneView.autoenablesDefaultLighting = true
        sceneView.automaticallyUpdatesLighting = true
        
        // Hook up status view controller callback(s).
        statusViewController.restartExperienceHandler = { [unowned self] in
            self.restartExperience()
        }
        
//        addBox()
        
//        addTapGestureToSceneView()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Prevent the screen from being dimmed to avoid interuppting the AR experience.
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Start the AR experience
        resetTracking()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        sceneView.session.pause()
    }
    
    // MARK: - ARSCNViewDelegate (Image Detection Results)
    /// - Tag: ARImageAnchor-Visualizin
    
    // Override to create and configure nodes for anchors added to the view's session.
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let imageAnchor = anchor as? ARImageAnchor else { return }
        print("Anchor ID = \(imageAnchor.identifier)")
        
        let referenceImage = imageAnchor.referenceImage
        
        // 1. Add a plane where imageAnchor is found
        updateQueue.async {
            
            let physicalWidth = referenceImage.physicalSize.width
            let physicalHeight = referenceImage.physicalSize.height
            
            // Create a plane to visualize the initial position of the detected image.
            let mainPlane = SCNPlane(width: physicalWidth, height: physicalHeight)
            
            let mainNode = SCNNode(geometry: mainPlane)
            
            mainNode.opacity = 0.25
            
            /*
             `SCNPlane` is vertically oriented in its local coordinate space, but
             `ARImageAnchor` assumes the image is horizontal in its local space, so
             rotate the plane to match.
             */
            mainNode.eulerAngles.x = -.pi / 2
            
            /*
             Image anchors are not tracked after initial detection, so create an
             animation that limits the duration for which the plane visualization appears.
             */
            mainNode.runAction(self.imageHighlightAction)
            
            // Add the plane visualization to the scene.
            node.addChildNode(mainNode)
            
            // Perform a quick animation to visualize the plane on which the image was detected.
            // We want to let our users know that the app is responding to the tracked image.
//            self.highlightDetection(on: mainNode, width: physicalWidth, height: physicalHeight, completionHandler: {

                // Load 3D Model
                self.display3DModel(on: node, xOffset: physicalWidth, yOffset: physicalHeight)

                // Introduce virtual content
                self.displayDetailView(on: node, xOffset: physicalWidth)

                // Animate the WebView to the right
                self.displayWebView(on: node, xOffset: physicalWidth)

//            })
        }
        
        DispatchQueue.main.async {
            let imageName = referenceImage.name ?? ""
            self.statusViewController.cancelAllScheduledMessages()
            self.statusViewController.showMessage("Detected image “\(imageName)”")
        }
    }
    
    var imageHighlightAction: SCNAction {
        return .sequence([
            .wait(duration: 0.25),
            .fadeOpacity(to: 0.85, duration: 0.25),
            .fadeOpacity(to: 0.15, duration: 0.25),
            .fadeOpacity(to: 0.85, duration: 0.25),
            .fadeOut(duration: 0.5),
            .removeFromParentNode()
            ])
    }
    
//    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
//
//        let node = SCNNode()
//
//        if let imageAnchor = anchor as? ARImageAnchor {
//
//            let referenceImage = imageAnchor.referenceImage
//            let physicalWidth = referenceImage.physicalSize.width
//            let physicalHeight = referenceImage.physicalSize.height
//
//            // Create a plane to visualize the initial position of the detected image.
//            let plane = SCNPlane(width: physicalWidth, height: physicalHeight)
//            plane.firstMaterial?.diffuse.contents = videoPlayer
//            self.videoPlayer.play()
//
//            let planeNode = SCNNode(geometry: plane)
//            planeNode.eulerAngles.x = -.pi / 2
//
//            node.addChildNode(planeNode)
//        }
//
//        return node
//
//    }
    
    // MARK: - Session management (Image detection setup)
    
    /// Prevents restarting the session while a restart is in progress.
    var isRestartAvailable = true
    
    /// Creates a new AR configuration to run on the `session`.
    /// - Tag: ARReferenceImage-Loading
    func resetTracking() {
        
        session.run(defaultConfiguration, options: [.resetTracking, .removeExistingAnchors])
        
        statusViewController.scheduleMessage("Look around to detect images", inSeconds: 7.5, messageType: .contentPlacement)
    }
    
    // MARK: - Load model and touch to place
    
    /// Place a box geometry on camera view based on vector postion - must be translated to real world coordinates
    ///
    /// - Parameters:
    ///   - x: Float
    ///   - y: Fload
    ///   - z: Float
    func addBox(x: Float = 0, y: Float = 0, z: Float = -0.2) {
        let box = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0)
        
        let boxNode = SCNNode()
        boxNode.geometry = box
        boxNode.position = SCNVector3(x, y, z)
        
        let scene = SCNScene()
        scene.rootNode.addChildNode(boxNode)
        
        sceneView.scene = scene
    }
    
    func addTapGestureToSceneView() {
        let tapGestureRecognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(self.didTap(withGestureRecognizer:)))
        sceneView.addGestureRecognizer(tapGestureRecognizer)
        
    }
    
    @objc func didTap(withGestureRecognizer recognizer: UIGestureRecognizer) {
        let tapLocation = recognizer.location(in: sceneView)
        let hitTestResults = sceneView.hitTest(tapLocation)
        
        guard let node = hitTestResults.first?.node else {
            let hitTestResultWithFeaturePoints = sceneView.hitTest(tapLocation, types: .featurePoint)
            
            if let hitTestResultWithFeaturePoints = hitTestResultWithFeaturePoints.first {
                let translation = hitTestResultWithFeaturePoints.worldTransform.translation
                addBox(x: translation.x, y: translation.y, z: translation.z)
            }
            return
        }
        node.removeFromParentNode()
    }
    
    // MARK: - Virtual Contents
    
    func display3DModel(on rootNode: SCNNode, xOffset: CGFloat, yOffset: CGFloat) {
//        let box = SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0)
//
//        let boxNode = SCNNode(geometry: box)
//        boxNode.position = SCNVector3Zero
//        boxNode.eulerAngles.x = -.pi / 2
//
//        rootNode.addChildNode(boxNode)
        
        // Ship Scene
        let shipScene = SCNScene(named: "art.scnassets/ship.scn")!
        
        let shipNode = shipScene.rootNode.childNode(withName: "ship", recursively: true)!
        
        // 2. Calculate size based on planeNode's bounding box.
        let (min, max) = shipNode.boundingBox
        let shipSize = SCNVector3Make(max.x - min.x, max.y - min.y, max.z - min.z)
        
        // 3. Calculate the ratio of difference between real image and object size.
        // Ignore Y axis because it will be pointed out of the image.
        // Pick smallest value to be sure that object fits into the image.
        let widthRatio = Float(xOffset)/shipSize.x
        let heightRatio = Float(yOffset)/shipSize.z
        let finalRatio = [widthRatio, heightRatio].min()!
        
        // 4. Set transform from imageAnchor data.
//        shipNode.transform = SCNMatrix4(imageAnchor.transform)
//        shipNode.transform = rootNode.transform
        
        // 5. Animate appearance by scaling model from 0 to previously calculated value.
        let appearanceAction = SCNAction.scale(to: CGFloat(finalRatio), duration: 0.4)
        appearanceAction.timingMode = .easeOut
        
//        shipNode.scale = SCNVector3Make(0, 0, 0)
        shipNode.scale = SCNVector3(0.15, 0.15, 0.15)
        
        // NOTICE: No need, Convert SpriteKitScene coordinate -> ARKit Coordinate
//        shipNode.eulerAngles.x = -.pi / 2
        shipNode.position = SCNVector3Zero
        shipNode.position.z = 0.05
        
//        let rotationAction = SCNAction.rotateBy(x: 0, y: 0.5, z: 0, duration: 1)
//        let infitieAction = SCNAction.repeatForever(rotationAction)
//        shipNode.runAction(infitieAction)
        
//        shipNode.runAction(appearanceAction)
        
        rootNode.addChildNode(shipNode)
    }
    
    func displayDetailView(on rootNode: SCNNode, xOffset: CGFloat) {
        let detailSKScene = SKScene(fileNamed: "DetailScene")
        detailSKScene?.isPaused = false
        
        // Create a plane
        let detailPlane = SCNPlane(width: xOffset, height: xOffset * 1.4)
        detailPlane.firstMaterial?.diffuse.contents = detailSKScene
        // Due to the origin of the iOS coordinate system, SCNMaterial's content appears upside down, so flip the y-axis.
        detailPlane.firstMaterial?.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(1, -1, 1), 0, 1, 0)
//        detailPlane.cornerRadius = 0.05
        
        // Put content on this plane
        let detailNode = SCNNode(geometry: detailPlane)
//        detailNode.position = SCNVector3Zero
        detailNode.eulerAngles.x = -.pi / 2
        detailNode.opacity = 0
        
        detailNode.runAction(.sequence([
            .wait(duration: 0.5),
            .fadeOpacity(to: 1.0, duration: 1.5),
            .moveBy(x: xOffset * -1.1, y: 0, z: 0, duration: 1.0),
//            .moveBy(x: 0, y: 0, z: 0.05, duration: 0.2)
            ])
        )
        
        rootNode.addChildNode(detailNode)
    }
    
    func displayWebView(on rootNode: SCNNode, xOffset: CGFloat) {
        // Xcode yells at us about the deprecation of UIWebView in iOS 12.0, but there is currently
        // a bug that does now allow us to use a WKWebView as a texture for our webViewNode
        // Note that UIWebViews should only be instantiated on the main thread!
        DispatchQueue.main.async {
            let request = URLRequest(url: URL(string: "https://en.wikipedia.org/wiki/African_elephant")!)
            let webView = UIWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 672))
            webView.loadRequest(request)
            
            let webViewPlane = SCNPlane(width: xOffset, height: xOffset * 1.4)
//            webViewPlane.cornerRadius = 0.25
            
            let webViewNode = SCNNode(geometry: webViewPlane)
            
            // Set the web view as webViewPlane's primary texture
            webViewNode.geometry?.firstMaterial?.diffuse.contents = webView
            webViewNode.eulerAngles.x = -.pi / 2
            webViewNode.opacity = 0
            
            webViewNode.runAction(.sequence([
                .wait(duration: 3.0),
                .fadeOpacity(to: 1.0, duration: 1.5),
                .moveBy(x: xOffset * 1.1, y: 0, z: 0, duration: 1.0),
//                .moveBy(x: 0, y: 0, z: -0.05, duration: 0.2)
                ])
            )
            
            rootNode.addChildNode(webViewNode)
        }
    }
    
    func highlightDetection(on rootNode: SCNNode, width: CGFloat, height: CGFloat, completionHandler block: @escaping (() -> Void)) {
        // Create a plane to visualize the initial position of the detected image.
        let mainPlane = SCNPlane(width: width, height: height)
        
        // This bit is important. It helps us create occlusion so virtual things stay hidden behind the detected image
//        mainPlane.firstMaterial?.colorBufferWriteMask = .alpha
        
        let planeNode = SCNNode(geometry: mainPlane)
//        planeNode.geometry?.firstMaterial?.diffuse.contents = UIColor.white
//        planeNode.position.z += 0.1
        planeNode.opacity = 0.25
        planeNode.eulerAngles.x = -.pi / 2
    
        planeNode.runAction(self.imageHighlightAction) {
            block()
        }
        
        rootNode.addChildNode(planeNode)
    }
    
    
    /// MARK: - Video Player
    
    // Load video and create video player
    let videoPlayer : AVPlayer = {
        // Load cat video from bundle
        guard let url = Bundle.main.url(forResource: "video", withExtension: "mp4") else {
            print("Could not find video file.")
            return AVPlayer()
        }
        return AVPlayer(url: url)
    }()
    
//    let players = [
//        "": videoplayer
//    ];
    
    func videoObserver(for videoPlayer: AVPlayer) {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: nil,
            using: {
                notification in videoPlayer.seek(to: CMTime.zero)
        })
    }
}

extension float4x4 {
    var translation: float3 {
        let translation = self.columns.3
        return float3(translation.x, translation.y, translation.z)
    }
}
