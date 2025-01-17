config = {
	'name': 'libre-graph-api',
	'rocketchat': {
		'channel': 'builds',
		'from_secret': 'private_rocketchat'
	},
	'branches': [
		'main'
	],
	'languages': {
		'go': {
			'src': "out-go",
			'repo-slug': "libre-graph-api-go",
			'branch': 'main',
		},
		'typescript-axios': {
			'src': "out-typescript-axios",
			'repo-slug': "libre-graph-api-typescript-axios",
			'branch': 'main',
		},
		'cpp-qt-client': {
			'src': "out-cpp-qt-client",
			'repo-slug': "libre-graph-api-cpp-qt-client",
			'branch': 'main',
		},
	},
	'openapi-generator-image': 'openapitools/openapi-generator-cli:latest@sha256:2957b6c14449411b92512602ad0ecff75dc5f164abc1cbc80769de4e7b711d4c'
}

def main(ctx):
	stages = stagePipelines(ctx)
	if (stages == False):
		print('Errors detected. Review messages above.')
		return []

	after = afterPipelines(ctx)
	dependsOn(stages, after)
	return stages + after

def stagePipelines(ctx):
	linters = linting(ctx)
	generators = generate(ctx, "go") + generate(ctx, "typescript-axios") + generate(ctx, "cpp-qt-client")
	dependsOn(linters, generators)
	return linters + generators

def afterPipelines(ctx):
	return [
		notify()
	]

def dependsOn(earlierStages, nextStages):
	for earlierStage in earlierStages:
		for nextStage in nextStages:
			nextStage['depends_on'].append(earlierStage['name'])

def notify():
	result = {
		'kind': 'pipeline',
		'type': 'docker',
		'name': 'chat-notifications',
		'clone': {
			'disable': True
		},
		'steps': [
			{
				'name': 'notify-rocketchat',
				'image': 'plugins/slack:1',
				'pull': 'always',
				'settings': {
					'webhook': {
						'from_secret': config['rocketchat']['from_secret']
					},
					'channel': config['rocketchat']['channel']
				}
			}
		],
		'depends_on': [],
		'trigger': {
			'ref': [
				'refs/tags/**'
			],
			'status': [
				'success',
				'failure'
			]
		}
	}

	for branch in config['branches']:
		result['trigger']['ref'].append('refs/heads/%s' % branch)

	return result

def linting(ctx):
	pipelines = []

	result = {
			'kind': 'pipeline',
			'type': 'docker',
			'name': 'lint',
			'steps': [
				{
					'name': 'validate',
					'image': config['openapi-generator-image'],
					'pull': 'always',
					'commands': [
						'/usr/local/bin/docker-entrypoint.sh validate -i api/openapi-spec/v0.0.yaml',
					],
				}
			],
			'depends_on': [],
			'trigger': {
				'ref': [
					'refs/pull/**',
					'refs/tags/**'
				]
			}
		}

	for branch in config['branches']:
		result['trigger']['ref'].append('refs/heads/%s' % branch)

	pipelines.append(result)

	return pipelines

def generate(ctx, lang):
	pipelines = []
	result = {
		'kind': 'pipeline',
		'type': 'docker',
		'name': 'generate-%s' % lang,
		'steps': [
			{
				"name": "clone-remote-%s" % lang,
				"image": "plugins/git-action:1",
				"pull": "always",
				"settings": {
					"actions": [
						"clone",
					],
					"remote": "https://github.com/owncloud/%s" % config["languages"][lang]["repo-slug"],
					"branch": "%s" % config["languages"][lang]["branch"],
					"path": "%s" % config["languages"][lang]["src"],
					"netrc_machine": "github.com",
					"netrc_username": {
						"from_secret": "github_username",
					},
					"netrc_password": {
						"from_secret": "github_token",
					},
				},
			},
			{
				'name': 'generate-%s' % lang,
				'image': config['openapi-generator-image'],
				'pull': 'always',
				'commands': [
					'test -d "templates/{0}" && TEMPLATE_ARG="-t templates/{0}" || TEMPLATE_ARG=""'.format(lang),
					'/usr/local/bin/docker-entrypoint.sh generate --enable-post-process-file -i api/openapi-spec/v0.0.yaml $${TEMPLATE_ARG} --additional-properties=packageName=libregraph --git-user-id=owncloud --git-repo-id=%s -g %s -o %s' % (config["languages"][lang]["repo-slug"], lang, config["languages"][lang]["src"]),
				],
			},
			{
				"name": "diff",
				"image": "owncloudci/alpine:latest",
				"commands": [
					"cd %s" % config["languages"][lang]["src"],
					"git diff",
				],
			},
			{
				"name": "publish-%s" % lang,
				"image": "plugins/git-action:1",
				"settings": {
					"actions": [
						"commit",
						"push",
					],
					"message": "%s" % ctx.build.message,
					"branch": "%s" % config["languages"][lang]["branch"],
					"path": "%s" % config["languages"][lang]["src"],
					"author_email": "%s" % ctx.build.author_email,
					"author_name": "%s" % ctx.build.author_name,
					"followtags": True,
					"remote" : "https://github.com/owncloud/%s" % config["languages"][lang]["repo-slug"],
					"netrc_machine": "github.com",
					"netrc_username": {
						"from_secret": "github_username",
					},
					"netrc_password": {
						"from_secret": "github_token",
					},
				},
				"when": {
					"ref": {
						"exclude": [
							"refs/pull/**",
						],
					},
				},
			},
			] + validate(lang),
		'depends_on': [],
		'trigger': {
			'ref': [
				'refs/tags/**',
				'refs/pull/**',
			]
		}
	}

	for branch in config['branches']:
		result['trigger']['ref'].append('refs/heads/%s' % branch)

	pipelines.append(result)

	return pipelines

def validate(lang):
	steps = {
		"cpp-qt-client": [
			{
				"name": "validate-cpp",
				"image": "owncloudci/client",
				"commands": [
					"cd %s/client" % config["languages"][lang]["src"],
					"cmake -GNinja .",
					"ninja -j1",
				]
			}
		],
		"go": [
			{
				"name": "go-mod",
				"image": "owncloudci/golang:1.17",
				"commands": [
					"cd %s" % config["languages"][lang]["src"],
					"go mod tidy",
				]
			},
			{
				"name": "validate-go",
				"image": "golangci/golangci-lint:latest",
				"commands": [
					"cd %s" % config["languages"][lang]["src"],
					"golangci-lint run -v",
				]
			},
		],
		"typescript-axios": []
	}

	return steps[lang]
