'use strict'

$ ->
	$('.masthead').visibility
		once: false
		onBottomPassed: ->
			$('.fixed.menu').transition 'fade in'
		onBottomPassedReverse: ->
			$('.fixed.menu').transition 'fade out'

	# create sidebar and attach to menu open
	$('.ui.sidebar').sidebar 'attach events', '.toc.item'
	$('.ui.search').search()

	# utils
	samplerToConfig = (sampler, config)->
		switch sampler.filter
			when 'nearest'
				config.filter = gl.NEAREST
			when 'linear'
				config.filter = gl.LINEAR
			when 'mipmap'
				config.filter = gl.LINEAR_MIPMAP_NEAREST
			else
				console.log("Unexpected filter: #{sampler.filter}", sampler)

		switch sampler.wrap
			when 'clamp'
				config.wrap = gl.CLAMP_TO_EDGE
			when 'repeat'
				config.wrap = gl.REPEAT
			else
				console.log("Unexpected wrap: #{sampler.wrap}", sampler)

		switch sampler.vflip
			when 'true'
				config.flipY = true
			when 'false'
				config.flipY = false
			else
				console.log("Unexpected vflip: #{sampler.vflip}", sampler)

	#polyfill
	navigator.getUserMedia = navigator.getUserMedia or navigator.webkitGetUserMedia or navigator.mozGetUserMedia or navigator.msGetUserMedia

	#WebGL
	gl = twgl.getWebGLContext(document.querySelector('#home'))

	imagePass = null
	imagePassTextures = {}
	imagePassTexturesConfig = {}
	imagePassChannelResolution = new Float32Array(12)

	#TODO: soundPass
	for pass in window.shader.renderpass
		switch pass.type
			when 'image'
				if imagePass
					console.log("Pass ignored: #{pass.type}", pass)
				else
					imagePass = pass
			else
				console.log("Pass ignored: #{pass.type}", pass)

	#TODO: imagePass: video, webcam, keyboard
	#TODO: soundPass: texture
	headCode = $('#head').text()
	imagePass.inputs.forEach (input)->
		switch input.ctype
			when 'texture', 'cubemap'
				textureConfig = {}

				if input.ctype == 'texture'
					textureConfig.src = window.config['asset.host'] + input.src
				else
					headCode = headCode.replace("sampler2D #{'iChannel' + input.channel}", "samplerCube #{'iChannel' + input.channel}")
					textureConfig.target = gl.TEXTURE_CUBE_MAP
					textureConfig.src = input.src.map (src)->
						window.config['asset.host'] + src

				samplerToConfig(input.sampler, textureConfig)
				imagePassTexturesConfig['iChannel' + input.channel] = textureConfig
			when 'music', 'mic'
				context = new AudioContext()
				analyser = context.createAnalyser()
				gain = context.createGain()

				#NOTE: Only low frequency component(lower half) is taken, the next line should be commented
				#analyser.fftSize = 1024
				analyser.connect(gain)
				gain.connect(context.destination)

				if input.ctype == 'music'
					audio = new Audio()
					audio.src = window.config['asset.host'] + input.src
					audio.autoplay = true
					audio.loop = true
					source = context.createMediaElementSource(audio)
					source.connect(analyser)
				else
					navigator.getUserMedia {audio: true}, (stream)->
						source = context.createMediaStreamSource(stream)
						source.connect(analyser)
					, (error)->
						console.error(error) if error

				buffer = new ArrayBuffer(1024)
				freq = new Uint8Array(buffer, 0, 512)
				wave = new Uint8Array(buffer, 512, 512)

				textureConfig =
					filter: gl.LINEAR
					wrap: gl.CLAMP_TO_EDGE
					format: gl.LUMINANCE
					src: new Uint8Array(buffer)
					width: 512
					height: 2
					update: ->
						analyser.getByteFrequencyData(freq)
						analyser.getByteTimeDomainData(wave)
						imagePassTextures['iChannel' + input.channel] = twgl.createTexture(gl, textureConfig)

				textureConfig.update()
				imagePassTexturesConfig['iChannel' + input.channel] = textureConfig
			when 'video', 'webcam'
				video = document.createElement('video')

				if input.ctype == 'video'
					video.src = window.config['asset.host'] + input.src
					video.loop = true
				else
					navigator.getUserMedia {video: true}, (stream)->
						video.src = URL.createObjectURL(stream)
					, (error)->
						console.error(error) if error

				textureConfig =
					src: video
					update: ->
						imagePassTextures['iChannel' + input.channel] = twgl.createTexture(gl, textureConfig)

				samplerToConfig(input.sampler, textureConfig)
				video.addEventListener 'canplay', ->
					video.width = @videoWidth
					video.height = @videoHeight
					video.play()
					imagePassTextures['iChannel' + input.channel] = twgl.createTexture(gl, textureConfig)
					imagePassTexturesConfig['iChannel' + input.channel] = textureConfig
					imagePassChannelResolution[input.channel * 3] = @videoWidth
					imagePassChannelResolution[input.channel * 3 + 1] = @videoHeight
			else
				console.log("Input ignored: #{input.ctype}", input)

	imagePassTextures = twgl.createTextures gl, imagePassTexturesConfig, (error, texs, imgs)->
		if error
			console.error(error)
		else
			imagePass.inputs.forEach (input)->
				switch input.ctype
					when 'texture', 'cubemap'
						imagePassChannelResolution[input.channel * 3] = imgs['iChannel' + input.channel].width
						imagePassChannelResolution[input.channel * 3 + 1] = imgs['iChannel' + input.channel].height
					when 'music', 'mic'
						imagePassChannelResolution[input.channel * 3] = 512
						imagePassChannelResolution[input.channel * 3 + 1] = 2
					when 'video', 'webcam'
						#pass
					else
						console.log("Input ignored again: #{input.ctype}", input)

	programInfo = twgl.createProgramInfo(gl, ['pass', headCode + imagePass.code])
	bufferInfo = twgl.createBufferInfoFromArrays(gl, {
		position: {
			numComponents: 2,
			data: [
				1.0, 1.0,
				-1.0, 1.0,
				1.0, -1.0,
				-1.0, -1.0
			]
		}
	})

	mouse = new Float32Array(4)
	$('#home').mousedown ->
		base = $(this).offset()
		mouse[2] = event.pageX - base.left
		mouse[3] = event.pageY - base.top

		$(this).mousemove (event)->
			offset = $(this).offset()
			mouse[0] = event.pageX - offset.left
			mouse[1] = event.pageY - offset.top

	$('#home').mouseup ->
		$(this).unbind('mousemove')

	render = (time)->
		twgl.resizeCanvasToDisplaySize(gl.canvas);
		gl.viewport(0, 0, gl.canvas.width, gl.canvas.height)

		#TODO: iChannelTime
		d = new Date()
		uniforms =
			iResolution: [gl.canvas.width, gl.canvas.height, 0]
			iGlobalTime: time / 1000
			iChannelTime: [0, 0, 0, 0]
			iChannelResolution: imagePassChannelResolution
			iMouse: mouse
			iDate: [d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()*3600 + d.getMinutes()*60 + d.getSeconds() + d.getMilliseconds()/1000]
			iSampleRate: 441000

		for channel, texture of imagePassTextures
			uniforms[channel] = texture

		twgl.setUniforms(programInfo, uniforms)
		twgl.drawBufferInfo(gl, gl.TRIANGLE_STRIP, bufferInfo)

		requestAnimationFrame(render)

		# All done, update inputs
		for channel, config of imagePassTexturesConfig
			config.update() if config.update

	gl.useProgram(programInfo.program)
	twgl.setBuffersAndAttributes(gl, programInfo, bufferInfo)
	requestAnimationFrame(render)
