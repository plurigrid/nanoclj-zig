[Deep learning as program synthesis](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#)

49 min read

•

[Background](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Background)

•

[Looking inside](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Looking_inside)

•

[Grokking](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Grokking)

•

[Vision circuits](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Vision_circuits)

•

[The hypothesis](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#The_hypothesis)

•

[What do I mean by “programs”?](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#What_do_I_mean_by__programs__)

•

[What do I mean by “program synthesis”?](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#What_do_I_mean_by__program_synthesis__)

•

[What’s the scope of the hypothesis?](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#What_s_the_scope_of_the_hypothesis_)

•

[Why this isn't enough](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Why_this_isn_t_enough)

•

[Indirect evidence](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Indirect_evidence)

•

[The paradox of approximation](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#The_paradox_of_approximation)

•

[The paradox of generalization](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#The_paradox_of_generalization)

•

[The paradox of convergence](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#The_paradox_of_convergence)

•

[The path forward](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#The_path_forward)

•

[The representation problem](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#The_representation_problem)

•

[The search problem](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#The_search_problem)

•

[Appendix](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Appendix)

•

[Related work](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Related_work)

[Interpretability (ML & AI)](https://www.lesswrong.com/w/interpretability-ml-and-ai)[Singular Learning Theory](https://www.lesswrong.com/w/singular-learning-theory)[AI](https://www.lesswrong.com/w/ai) [Frontpage](https://www.lesswrong.com/posts/5conQhfa4rgb4SaWx/site-guide-personal-blogposts-vs-frontpage-posts)
[2026 Top Fifty: 17%](https://manifold.markets/LessWrong/will-deep-learning-as-program-synth)

# 140

1010

ChaptersSpeed 1XSubscribe

Deep learning as program synthesis

00:00 / 01:11:43

Speed 1x

Chapter 1Background

02:31Background

09:06Looking inside

09:09Grokking

16:04Vision circuits

22:37The hypothesis

26:04Why this isnt enough

27:22Indirect evidence

32:44The paradox of approximation

38:34The paradox of generalization

45:44The paradox of convergence

51:46The path forward

53:20The representation problem

58:38The search problem

01:07:20Appendix

01:07:23Related work

00:00 / 01:11:43

[Apple](https://podcasts.apple.com/us/podcast/lesswrong-30+-karma/id1698192712)

[Spotify](https://open.spotify.com/show/3teJ17Kn2xs9pMMRcMAWuQ)

[RSS](https://feeds.type3.audio/lesswrong--30-karma.rss)

0.5x5x

1x

1010

00:00 / 01:11:43

ChaptersSpeed 1XSubscribe

Chapter 1Background

02:31Background

09:06Looking inside

09:09Grokking

16:04Vision circuits

22:37The hypothesis

26:04Why this isnt enough

27:22Indirect evidence

32:44The paradox of approximation

38:34The paradox of generalization

45:44The paradox of convergence

51:46The path forward

53:20The representation problem

58:38The search problem

01:07:20Appendix

01:07:23Related work

00:00 / 01:11:43

[Apple](https://podcasts.apple.com/us/podcast/lesswrong-30+-karma/id1698192712)

[Spotify](https://open.spotify.com/show/3teJ17Kn2xs9pMMRcMAWuQ)

[RSS](https://feeds.type3.audio/lesswrong--30-karma.rss)

0.5x5x

1x

# [Deep learning as programsynthesis](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1)

by [Zach Furman](https://www.lesswrong.com/users/zach-furman?from=post_header)

20th Jan 2026

49 min read

[33](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#comments)

# 140

_Epistemic status: This post is a synthesis of ideas that are, in my experience, widespread among researchers at frontier labs and in mechanistic interpretability, but rarely written down comprehensively in one place - different communities tend to know different pieces of evidence. The core hypothesis - that deep learning is performing something like tractable program synthesis - is not original to me (even to me, the ideas are ~3 years old), and I suspect it has been arrived at independently many times. (See the appendix on related work)._

_This is also far from finished research - more a snapshot of a hypothesis that seems increasingly hard to avoid, and a case for why formalization is worth pursuing. I discuss the key barriers and how tools like singular learning theory might address them towards the end of the post._

_Thanks to Dan Murfet, Jesse Hoogland, Max Hennick, and Rumi Salazar for feedback on this post._

> Sam Altman: Why does unsupervised learning work?
>
> Dan Selsam: Compression. So, the ideal intelligence is called _Solomonoff induction_…[\[1\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnz8jpod2itgo)

The central hypothesis of this post is that **deep learning succeeds because it's performing a tractable form of program synthesis** \- searching for simple, compositional algorithms that explain the data. If correct, this would reframe deep learning's success as an instance of something we understand in principle, while pointing toward what we would need to formalize to make the connection rigorous.

I first review the theoretical ideal of Solomonoff induction and the empirical surprise of deep learning's success. Next, mechanistic interpretability provides direct evidence that networks learn algorithm-like structures; I examine the cases of grokking and vision circuits in detail. Broader patterns provide indirect support: how networks evade the curse of dimensionality, generalize despite overparameterization, and converge on similar representations. Finally, I discuss what formalization would require, why it's hard, and the path forward it suggests.

# Background

> Whether we are a detective trying to catch a thief, a scientist trying to discover a new physical law, or a businessman attempting to understand a recent change in demand, we are all in the process of collecting information and trying to infer the underlying causes.
>
> _-Shane Legg_[\[2\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fn9y7nox8uh2)

Early in childhood, human babies learn _object permanence_ \- that unseen objects nevertheless persist even when not directly observed. In doing so, their world becomes a little less confusing: it is no longer surprising that their mother appears and disappears by putting hands in front of her face. They move from raw sensory perception towards interpreting their observations as coming from an _external world:_ a coherent, self-consistent process which determines what they see, feel, and hear.

As we grow older, we refine this model of the world. We learn that fire hurts when touched; later, that one can create fire with wood and matches; eventually, that fire is a chemical reaction involving fuel and oxygen. At each stage, the world becomes less magical and more predictable. We are no longer surprised when a stove burns us or when water extinguishes a flame, because we have learned the underlying process that governs their behavior.

This process of learning only works because the world we inhabit, for all its apparent complexity, is not random. It is governed by consistent, discoverable rules. If dropping a glass causes it to shatter on Tuesday, it will do the same on Wednesday. If one pushes a ball off the top of a hill, it will roll down, at a rate that any high school physics student could predict. Through our observations, we implicitly reverse-engineer these rules.

This idea - that the physical world is fundamentally predictable and rule-based - has a formal name in computer science: the [_physical Church-Turing thesis_](https://plato.stanford.edu/entries/church-turing/#ChurTuriThesPhys). Precisely, it states that any physical process can be simulated to arbitrary accuracy by a Turing machine. Anything from a star collapsing to a neuron firing, can, in principle, be described by an algorithm and simulated on a computer.

From this perspective, one can formalize this notion of "building a world model by reverse-engineering rules from what we can see." We can operationalize this as a form of **program synthesis**: from observations, attempting to reconstruct some approximation of the "true" program that generated those observations. Assuming the physical Church-Turing thesis, such a learning algorithm would be "universal," able to eventually represent and predict any real-world process.

But this immediately raises a new problem. For any set of observations, there are infinitely many programs that could have produced them. How do we choose? The answer is one of the oldest principles in science: _Occam's razor_. We should prefer the simplest explanation.

In the 1960s, Ray Solomonoff formalized this idea into a theory of _universal induction_ which we now call **Solomonoff induction**. He defined the "simplicity" of a hypothesis as the length of the shortest program that can describe it (a concept known as _Kolmogorov complexity_). An ideal Bayesian learner, according to Solomonoff, should prefer hypotheses (programs) that are short over ones that are long. This learner can, in theory, learn _anything_ that is computable, because it searches the space of all possible programs, using simplicity as its guide to navigate the infinite search space and generalize correctly.

The invention of Solomonoff induction began[\[3\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fn9w6g132qlp) a rich and productive subfield of computer science, _algorithmic information theory_, which persists to this day. Solomonoff induction is still widely viewed as the _ideal_ or _optimal_ self-supervised learning algorithm, which one can prove formally under some assumptions[\[4\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnjxst5sv8a9). These ideas (or extensions of them like [_AIXI_](https://en.wikipedia.org/wiki/AIXI)) were influential for early deep learning thinkers like [Jürgen Schmidhuber](https://gwern.net/doc/reinforcement-learning/model/2002-schmidhuber.pdf) and [Shane Legg](http://www.vetta.org/documents/Machine_Super_Intelligence.pdf), and shaped a [line of ideas](https://www.hutter1.net/publ/suaigentle.pdf) attempting to theoretically predict how smarter-than-human machine intelligence might behave, especially [within](https://www.lesswrong.com/posts/Tr7tAyt5zZpdTwTQK/the-solomonoff-prior-is-malign)[AI](https://ai-alignment.com/better-priors-as-a-safety-problem-24aa1c300710)[safety](https://www.lesswrong.com/posts/MvfD4tmzyuCYFqB2f/open-problems-in-aixi-agent-foundations).

Unfortunately, despite its mathematical beauty, Solomonoff induction is completely intractable. Vanilla Solomonoff induction is _incomputable_, and even approximate versions like [speed induction](https://gwern.net/doc/reinforcement-learning/model/2002-schmidhuber.pdf) are exponentially slow[\[5\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnl2yn9dinv). Theoretical interest in it as a "platonic ideal of learning" remains to this day, but practical artificial intelligence has long since moved on, assuming it to be hopelessly unfeasible.

* * *

Meanwhile, neural networks were producing results that nobody had anticipated.

This was not the usual pace of scientific progress, where incremental advances accumulate and experts see breakthroughs coming. In 2016, most Go researchers thought human-level play was decades away; AlphaGo arrived that year. Protein folding had resisted fifty years of careful work; AlphaFold essentially solved it[\[6\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fn6vd5zchhq54) over a single competition cycle. Large language models began writing code, solving competition math problems, and engaging in apparent reasoning - capabilities that emerged from next-token prediction without ever being explicitly specified in the loss function. At each stage, domain experts (not just outsiders!) were caught off guard. If we understood what was happening, we would have predicted it. We did not.

The field's response was pragmatic: scale the methods that work, stop trying to understand why they work. This attitude was partly earned. For decades, hand-engineered systems encoding human knowledge about vision or language had lost to generic architectures trained on data. Human intuitions about what mattered kept being wrong. But the pragmatic stance hardened into something stronger - a tacit assumption that trained networks were _intrinsically_ opaque, that asking what the weights meant was a category error.

At first glance, this assumption seemed to have some theoretical basis. If neural networks were best understood as "just curve-fitting" function approximators, then there was no obvious reason to expect the learned parameters to mean anything in particular. They were solutions to an optimization problem, not representations. And when researchers did look inside, they found dense matrices of floating-point numbers with no obvious organization.

But a lens that predicts opacity makes the same prediction whether structure is absent or merely invisible. Some researchers kept looking.

# **Looking inside**

## **Grokking**

![](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/iFymqTKHgftbzqMy7/b3shtwfqaa9h8dbp6msu)![](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/iFymqTKHgftbzqMy7/zowq4s7w0swowyi3jojy)The modular addition transformer from [Power et al. (2022)](https://arxiv.org/abs/2201.02177) learns to generalize rapidly (top), at the same time as Fourier modes in the weights appear (bottom right). Illustration by [Pearce et al. (2023)](https://pair.withgoogle.com/explorables/grokking/).

[Power et al. (2022)](https://arxiv.org/abs/2201.02177) train a small transformer on modular addition: given two numbers, output their sum mod 113. Only a fraction of the possible input pairs are used for training - say, 30% - with the rest held out for testing.

The network memorizes the training pairs quickly, getting them all correct. But on pairs it hasn't seen, it does no better than chance. This is unsurprising: with enough parameters, a network can simply store input-output associations without extracting any rule. And stored associations don't help you with new inputs.

Here's what's unexpected. If you keep training, despite the training loss already nearly as low as it can go, the network eventually starts getting the _held-out pairs_ right too. Not gradually, either: test performance jumps from chance to near perfect over only a few thousand training steps.

So something has changed inside the network. But what? It was already fitting the training data; the data didn't change. There's no external signal that could have triggered the shift.

One way to investigate is to look at the weights themselves. We can do this at multiple checkpoints over training and ask: does something change in the weights around the time generalization begins?

It does. The weights early in training, during the memorization phase, don't have much structure when you analyze them. Later, they do. Specifically, if we look at the embedding matrix, we find that it's mapping numbers to particular locations on a circle. The number 0 maps to one position, 1 maps to a position slightly rotated from that, and so on, wrapping around. More precisely: the embedding of each number contains sine and cosine values at a small set of specific frequencies.

This structure is absent early in training. It emerges as training continues, and it emerges around the same time that generalization begins.

So what is this structure doing? Following it through the network reveals something unexpected: _the network has learned an algorithm for modular addition based on trigonometry_.[\[7\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fniejpex45eha)

![](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/iFymqTKHgftbzqMy7/ltrbeb5byitajyxxxpp6)A transformer trained on a modular addition task learns a compositional, human-interpretable algorithm. Reverse-engineered by [Nanda et al. (2023)](https://arxiv.org/abs/2301.05217). Image from [Nanda et al. (2023)](https://arxiv.org/abs/2301.05217).

The algorithm exploits how angles add. If you represent a number as a position on a circle, then adding two numbers corresponds to adding their angles. The network's embedding layer does this representation. Its middle layers then combine the sine and cosine values of the two inputs using trigonometric identities. These operations are implemented in the weights of the attention and MLP layers: one can read off coefficients that correspond to the terms in these identities.

Finally, the network needs to convert back to a discrete answer. It does this by checking, for each possible output c, how well c matches the sum it computed. Specifically, the logit for output c depends on cos(2πk(a+b−c)/P). This quantity is maximized when c equals a+bmodP \- the correct answer. At that point the cosines at different frequencies all equal 1 and add constructively. For wrong answers, they point in different directions and cancel.

This isn't a loose interpretive gloss. Each piece - the circular embedding, the trig identities, the interference pattern - is concretely present in the weights and can be verified by ablations.

So here's the picture that emerges. During the memorization phase, the network solves the task some other way - presumably something like a lookup table distributed across its parameters. It fits the training data, but the solution doesn't extend. Then, over continued training, a different solution forms: this trigonometric algorithm. As the algorithm assembles, generalization happens. The two are not merely correlated; tracing the structure in the weights and the performance on held-out data, they move together.

What should we make of this? Here’s one reading: the difference between a network that memorizes and a network that generalizes is not just quantitative, but qualitative. The two networks have learned different kinds of things. One has stored associations. The other has found a method - a mechanistic procedure that happens to work on inputs beyond those it was trained on, because it captures something about the structure of the problem.

This is a single example, and a toy one. But it raises a question worth taking seriously. When networks generalize, _is it because they've found something like an algorithm?_ And if so, what does that tell us about what deep learning is actually doing?

It's worth noting what was and wasn't in the training data. The data contained input-output pairs: "32 and 41 gives 73," and so on. It contained nothing about _how_ to compute them. The network arrived at a method on its own.

And both solutions - the lookup table and the trigonometric algorithm - fit the training data equally well. The network's loss was already near minimal during the memorization phase. Whatever caused it to keep searching, to eventually settle on the generalizing algorithm instead, it wasn't that the generalizing algorithm fit the data better. It was something else - some property of the learning process that favored one kind of solution over another.

The generalizing algorithm is, in a sense, simpler. It compresses what would otherwise be thousands of stored associations into a compact procedure. Whether that's the right way to think about what happened here - whether "simplicity" is really what the training process favors - is not obvious. But something made the network prefer a mechanistic solution that generalized over one that didn't, and it wasn't the training data alone.[\[8\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnb5ms35mh16)

## **Vision circuits**

![](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/iFymqTKHgftbzqMy7/gkiflfpwpi6eofpu7lz9)InceptionV1 classifies an image as a car by hierarchically composing detectors for the windows, car body, and wheels (pictured), which are themselves formed by composing detectors for shapes, edges, etc (not pictured). From [Olah et al. (2020)](https://distill.pub/2020/circuits/zoom-in/).

Grokking is a controlled setting - a small network, a simple task, designed to be fully interpretable. Does the same kind of structure appear in realistic models solving realistic problems?

[Olah et al. (2020)](https://distill.pub/2020/circuits/zoom-in/) study InceptionV1, an image classification network trained on ImageNet - a dataset of over a million photographs labeled with object categories. The network takes in an image and outputs a probability distribution over a thousand possible labels: "car," "dog," "coffee mug," and so on. Can we understand this more realistic setting?

A natural starting point is to ask what individual neurons are doing. Suppose we take a neuron somewhere in the network. We can find images that make it activate strongly by either searching through a dataset or optimizing an input to maximize activation. If we collect images that strongly activate a given neuron, do they have anything in common?

In early layers, they do, and the patterns we find are simple. Neurons in the first few layers respond to edges at particular orientations, small patches of texture, transitions between colors. Different neurons respond to different orientations or textures, but many are selective for something visually recognizable.

In later layers, the patterns we find become more complex. Neurons respond to curves, corners, or repeating patterns. Deeper still, neurons respond to things like eyes, wheels, or windows - object parts rather than geometric primitives.

This already suggests a hierarchy: simple features early, complex features later. But the more striking finding is about how the complex features are built.

Olah et al. do not just visualize what neurons respond to. They trace the connections between layers - examining the weights that connect one layer's neurons to the next, identifying which earlier features contribute to which later ones. What they find is that later features are _composed_ from earlier ones in interpretable ways.

There is, for instance, a neuron in InceptionV1 that we identify as responding to dog heads. If we trace its inputs by looking at which neurons from the previous layer connect to it with strong weights, we find it receives input from neurons that detect eyes, snout, fur, and tongue. The dog head detector is built from the outputs of simpler detectors. It is not detecting dog heads from scratch; it is checking whether the right combination of simpler features is present in the right spatial arrangement.

We find the same pattern throughout the network. A neuron that detects car windows is connected to neurons that detect rectangular shapes with reflective textures. A neuron that detects car bodies is connected to neurons that detect smooth, curved surfaces. And a neuron that detects cars as a whole is connected to neurons that detect wheels, windows, and car bodies, arranged in the spatial configuration we would expect for a car.

Olah et al. call these pathways "circuits," and the term is meaningful. The structure is genuinely circuit-like: there are inputs, intermediate computations, and outputs, connected by weighted edges that determine how features combine. In their words: "You can literally read meaningful algorithms off of the weights."

And the components are reused. The same edge detectors that contribute to wheel detection also contribute to face detection, to building detection, to many other things. The network has not built separate feature sets for each of the thousand categories it recognizes. It has built a shared vocabulary of parts - edges, textures, curves, object components, etc - and combines them differently for different recognition tasks.

We might find this structure reminiscent of something. A Boolean circuit is a composition of simple gates - each taking a few bits as input, outputting one bit - wired together to compute something complex. A program is a composition of simple operations - each doing something small - arranged to accomplish something larger. What Olah et al. found in InceptionV1 has the same shape: small computations, composed hierarchically, with components shared and reused across different pathways.

From a theoretical computer science perspective, this is what algorithms look like, in general. Not just the specific trigonometric trick from grokking, but computation as such. You take a hard problem, break it into pieces, solve the pieces, and combine the results. What makes this tractable, what makes it an algorithm rather than a lookup table, is precisely the compositional structure. The reuse is what makes it compact; the compactness is what makes it feasible.

* * *

![](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/Dw8mskAvBX37MxvXo/g15t7lxzpynmgseag9yd)![](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/Dw8mskAvBX37MxvXo/ixuwdva4fe7zecpovpd1)[Olsson et al.](https://transformer-circuits.pub/2022/in-context-learning-and-induction-heads/index.html) argue that the primary mechanism of in-context-learning in large language models is a mechanistic attention circuit known as an _induction head_. Similar to the grokking example, the mechanistic circuit forms in a rapid "phase change" which coincides with a large improvement in the in-context-learning performance. Plots from [Olsson et al.](https://transformer-circuits.pub/2022/in-context-learning-and-induction-heads/index.html)

Grokking and InceptionV1 are two examples, but they are far from the only ones. Mechanistic interpretability has grown into a substantial field, and the researchers working in it have documented many such structures - in toy models, in language models, across different architectures and tasks. [Induction heads](https://transformer-circuits.pub/2022/in-context-learning-and-induction-heads/index.html), [language circuits](https://transformer-circuits.pub/2025/attribution-graphs/biology.html), and [bracket matching](https://transformer-circuits.pub/2025/linebreaks/index.html) in transformer language models, learned [world](https://arxiv.org/abs/2210.13382)[models](https://arxiv.org/abs/2412.11867) and [multi-step reasoning](https://arxiv.org/abs/2402.11917) in toy tasks, [grid-cell-like mechanisms](https://pubmed.ncbi.nlm.nih.gov/29743670/) in RL agents, [hierarchical representations](https://arxiv.org/abs/1811.10597) in GANs, and much more. Where we manage to look carefully, we tend to find something mechanistic.

This raises a question. If what we find inside trained networks (at least when we can find anything) looks like algorithms built from parts, what does that suggest about what deep learning is doing?

# **The hypothesis**

What should we make of this?

We have seen neural networks learn solutions that look like algorithms - compositional structures built from simple, reusable parts. In the grokking case, this coincided precisely with generalization. In InceptionV1, this structure is what lets the network recognize objects despite the vast dimensionality of the input space. And across many other cases documented in the mechanistic interpretability literature, the same shape appears: not monolithic black-box computations, but something more like circuits.

This is reminiscent of the picture we started with. Solomonoff induction frames learning as a search for simple programs that explain data. It is a theoretical ideal - provably optimal in a certain sense, but hopelessly intractable. The connection between Solomonoff and deep learning has mostly been viewed as purely conceptual: a nice way to think about what learning "should" do, with no implications for what neural networks actually do.

But the evidence from mechanistic interpretability suggests a different possibility. What if deep learning is doing something functionally similar to program synthesis? Not through the same mechanism - gradient descent on continuous parameters is nothing like enumerative search over discrete programs. But perhaps targeting the same kind of object: mechanistic solutions, built from parts, that capture structure in the data generating process.

To be clear: this is a hypothesis. The evidence shows that neural networks _can_ learn compositional solutions, and that such solutions _have_ appeared alongside generalization in specific, interpretable cases. It doesn't show that this is what's always happening, or that there's a consistent bias toward simplicity, or that we understand why gradient descent would find such solutions efficiently.

But if the hypothesis is right, it would reframe what deep learning is doing. The success of neural networks would not be a mystery to be accepted, but an instance of something we already understand in principle: the power of searching for compact, mechanistic models to explain your observations. The puzzle would shift from "why does deep learning work at all?" to "how does gradient descent implement this search so efficiently?"

That second question is hard. Solomonoff induction is intractable precisely because the space of programs is vast and discrete. Gradient descent navigates a continuous parameter space using only local information. If both processes are somehow arriving at similar destinations - compositional solutions to learning problems - then something interesting is happening in how neural network loss landscapes are structured, something we do not yet understand. We will return to this issue at the end of the post.

So the hypothesis raises as many questions as it answers. But it offers something valuable: a frame. If deep learning is doing a form of program synthesis, that gives us a way to connect disparate observations - about generalization, about convergence of representations, about why scaling works - into a coherent picture. Whether this picture can make sense of more than just these particular examples is what we'll explore next.

Clarifying the hypothesis

## **What do I mean by “programs”?**

I think one can largely read this post with a purely operational, “you know it when you see it” definition of “programs” and “algorithms”. But there are real conceptual issues here if you try to think about this carefully.

In most computational systems, there's a vocabulary that comes with the design - instructions, subroutines, registers, data flow, and so on. We can point to the “program” because the system was built to make it visible.

Neural networks are not like this. We have neurons, weights, activations, etc, but these may not be the right atoms of computation. If there's computational structure in a trained network, it doesn't automatically come labeled. So if we want to ask whether networks learn programs, we need to know what we're looking for. What would count as finding one?

This is a real problem for interpretability too. When researchers claim to find "circuits" or “features” in a network, what makes that a discovery rather than just a pattern they liked? There has to be something precise and substrate-independent we're tracking. It helps to step back and consider what computational structure even _is_ in the cases we understand it well.

Consider the various models of computation: Turing machines, lambda calculus, Boolean circuits, etc. They have different primitives - tapes, substitution rules, logic gates - but the Church-Turing thesis tells us they're equivalent. Anything computable in one is computable in all the others. So "computation" isn't any particular formalism. It's whatever these formalisms have in common.

What do they have in common? Let me point to something specific: each one builds complex operations by composing simple pieces, where each piece only interacts with a small number of inputs. A Turing machine's transition function looks at one cell. A Boolean gate takes two or three bits. A lambda application involves one function and one argument. Complexity comes from how pieces combine, not from any single piece seeing the whole problem.

Is this just a shared property, or something deeper?

One reason to take it seriously: you can derive a complete model of computation from just this principle. Ask "what functions can I build by composing pieces of bounded arity?" and work out the answer carefully. You get (in the discrete case) Boolean circuits - not a restricted fragment of computation, but a universal model, equivalent to all the others. The composition principle alone is enough to generate computation in full generality.

The bounded-arity constraint is essential. If each piece could see all inputs, we would just have lookup tables. What makes composition powerful is precisely that each piece is “local” and can only interact with so many things at once - it forces solutions to have genuine internal structure.

**So when I say networks might learn "programs," I mean: solutions built by composing simple pieces, each operating on few inputs.** Not because that's one nice kind of structure, but because that may be what computation actually is.

Note that we have not implied that the computation is necessarily over discrete _values_ \- it may be over continuous values, as in analog computation. (However, the “pieces” must be discrete, for this to even be a coherent notion. This causes issues when combined with the subsequent point, as we will discuss towards the end of the post.)

A clarification: the network's architecture trivially has compositional structure - the forward pass is executable on a computer. That's not the claim. The claim is that training discovers an effective program _within_ this substrate. Think of an FPGA: a generic grid of logic components that a hardware engineer configures into a specific circuit. The architecture is the grid; the learned weights are the configuration.

This last point, the fact that the program structure in neural networks is _learned_ and depends on _continuous_ parameters, is actually what makes this issue rather subtle, and unlike other models of computation we’re familiar with (even analog computation). This is a subtle issue which makes formalization difficult, an issue we will return to towards the end of the post.

## **What do I mean by “program synthesis”?**

By program synthesis, I mean a search through possible programs to find one that fits the data.

Two things make this different from ordinary function fitting.

First, the search is **general-purpose**. Linear regression searches over linear functions. Decision trees search over axis-aligned partitions. These are narrow hypothesis classes, chosen by the practitioner to match the problem. The claim here is different: deep learning searches over a space that can express essentially any efficient computable function. It's not that networks are good at learning one particular kind of structure - it's that they can learn whatever structure is there.

Second, the search is guided by **strong inductive biases**. Searching over all programs is intractable without some preference for certain programs over others. The natural candidate is simplicity: favor shorter or less complex programs over longer or more complex ones. This is what Solomonoff induction does - it assigns prior probability to programs based on their length, then updates on data.

Solomonoff induction is the theoretical reference point. It's provably optimal in a certain sense: if the data has any computable structure, Solomonoff induction will eventually find it. But it's also intractable - not just slow, but literally incomputable in its pure form, and exponentially slow even in approximations.

The hypothesis is that deep learning achieves something functionally similar through completely different means. Gradient descent on continuous parameters looks nothing like enumeration over discrete programs. But perhaps both are targeting the same kind of object - simple programs that capture structure - and arriving there by different routes. We will return to the issue towards the end of the post.

This would require the learning process to implement something like simplicity bias, even though "program complexity" isn't in the loss function. Whether that's exactly the right characterization, I'm not certain. But some strong inductive bias has to be operating - otherwise we couldn't explain why networks generalize despite having the capacity to memorize, or why scaling helps rather than hurts.

## **What’s the scope of the hypothesis?**

I've thought most deeply about supervised and self-supervised learning using stochastic optimization (SGD, Adam, etc) on standard architectures like MLPs, CNNs, or transformers, on standard tasks like image classification or autoregressive language prediction, and am strongly ready to defend claims there. I also believe that this extends to settings like diffusion models, adversarial setups, reinforcement learning, etc, but I've thought less about these and can't be as confident here.

## **Why this isn't enough**

The preceding case studies provide a strong **existence proof**: deep neural networks are capable of learning and implementing non-trivial, compositional algorithms. The evidence that InceptionV1 solves image classification by composing circuits, or that a transformer solves modular addition by discovering a Fourier-based algorithm, is quite hard to argue with. And, of course, there are more examples than these which we have not discussed.

Still, the question remains: **is this the exception or the rule?** It would be completely consistent with the evidence presented so far for this type of behavior to just be a strange edge case.

Unfortunately, mechanistic interpretability is not yet enough to settle the question. The settings where today's mechanistic interpretability tools provide such clean, complete, and unambiguously correct results[\[9\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnfqn67eo6jo5) are very rare.

Aren't most networks uninterpretable? Why this doesn't disprove the thesis.

Should we not take the lack of such clean mechanistic interpretability results as **active counterevidence** against our hypothesis? If models were truly learning programs in general, shouldn't those programs be readily apparent? Instead the internals of these systems appear far more "messy."

This objection is a serious one, but it makes a leap in logic. It conflates the statement "our current methods have not found a clean programmatic structure" with the much stronger statement "no such structure exists." In other words, _absence of evidence is not evidence of absence_[\[10\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fn8byhvyt3kqe). The difficulty we face may not be an absence of structure, but a mismatch between the network's chosen representational scheme and the tools we are currently using to search for it.

![](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/iFymqTKHgftbzqMy7/yhcrw67yxwml3ebmpp4p)Attempting to identify which individual transistors in an Atari machine are responsible for different games does not work very well; nevertheless an Atari machine has real computational structure. We may be in a similar situation with neural networks. From [Jonas & Kording (2017)](https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1005268).

To make this concrete, consider a thought experiment, adapted from the paper "[Could a Neuroscientist Understand a Microprocessor?](https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1005268)":

Imagine a team of neuroscientists studying a microprocessor (MOS 6502) that runs arcade (Atari) games. Their tools are limited to their trade: they can, for instance, probe the voltage of individual transistors and lesion them to observe the effect on gameplay. They do not have access to the high-level source code or architecture diagrams.

As the paper confirms, the neuroscientists would fail to understand the system. This failure would not be because the system lacks compositional, program structure - it is, by definition, a machine that executes programs. Their failure would be one of mismatched levels of abstraction. The meaningful concepts of the software (subroutines, variables, the call stack) have no simple, physical correlate at the transistor level. The "messiness" they would observe - like a single transistor participating in calculating a score, drawing a sprite, and playing a sound - is an illusion created by looking at the wrong organizational level.

My claim is that this is the situation we face with neural networks. Apparent "messiness" like [_polysemanticity_](https://arxiv.org/abs/2210.01892) is not evidence against a learned program; it is the expected signature of a program whose logic is not organized at the level of individual neurons. The network may be implementing something like a program, but using a "compiler" and an "instruction set" that are currently alien to us.[\[11\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnguz89j1a968)

The clean results from the vision and modular addition case studies are, in my view, instances where strong constraints (e.g., the connection sparsity of CNNs, or the heavy regularization and shallow architecture in the grokking setup) forced the learned program into a representation that happened to be unusually simple for us to read. They are the exceptions in their _legibility_, not necessarily in their underlying nature.[\[12\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fn969wylfycf)

Therefore, while mechanistic interpretability can supply _plausibility_ to our hypothesis, we need to move towards more indirect evidence to start building a positive case.

# **Indirect evidence**

> Just before OpenAI started, I met Ilya \[Sutskever\]. One of the first things he said to me was, "Look, the models, they just wanna learn. You have to understand this. The models, they just wanna learn."
>
> And it was a bit like a Zen Koan. I listened to this and I became  enlightened.
>
> ... What that told me is that the phenomenon that I'd seen wasn't just some random thing: it was broad, it was more general.
>
> The models just wanna learn. You get the obstacles out of their way. You give them good data. You give them enough space to operate in. You don't do something stupid like condition them badly numerically.
>
> And they wanna learn. They'll do it.
>
> - _Dario Amodei_[\[13\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnc45j78nx35)

I remember when I trained my first neural network, there was something almost miraculous about it: it could solve problems which I had absolutely no idea how to code myself (e.g. how to distinguish a cat from a dog), and in a completely opaque way such that even _after_ it had solved the problem I had no better picture for how to solve the problem myself than I did beforehand. Moreover, it was remarkably resilient, despite obvious problems with the optimizer, or bugs in the code, or bad training data - unlike any other engineered system I had ever built, almost reminiscent of something biological in its robustness.

My impression is that this sense of "magic" is a common, if often unspoken, experience among practitioners. Many simply learn to accept the mystery and get on with the work. But there is nothing virtuous about confusion - it just suggests that your understanding is incomplete, that you are ignorant of the real mechanisms underlying the phenomenon.

Our practical success with deep learning has outpaced our theoretical understanding. This has led to a proliferation of explanations that often feel **ad-hoc and local** \- tailor-made to account for a specific empirical finding, without connecting to other observations or any larger framework. For instance, the theory of "double descent" provides a narrative for the U-shaped test loss curve, but it is a self-contained story. It does not, for example, share a conceptual foundation with the theories we have for how induction heads form in transformers. Each new discovery seems to require a new, bespoke theory. One naturally worries that we are juggling epicycles.

This sense of theoretical fragility is compounded by a second problem: for any single one of these phenomena, we often lack consensus, entertaining multiple, **competing hypotheses**. Consider the core question of why neural networks generalize. Is it best explained by the implicit bias of SGD towards flat minima, the behavior of neural tangent kernels, or some other property? The field actively debates these views. And where no mechanistic theory has gained traction, we often retreat to descriptive labels. We say complex abilities are an "emergent" property of scale, a term that names the mystery without explaining its cause.

This theoretical disarray is sharpest when we examine our most foundational frameworks. Here, the issue is not just a lack of consensus, but a direct conflict with empirical reality. This disconnect manifests in several ways:

- Sometimes, our theories make predictions that are **actively falsified** by practice. Classical statistical learning theory, with its focus on the bias-variance tradeoff, advises against the very scaling strategies that have produced almost all state-of-the-art performance.
- In other cases, a theory might be technically true but **practically misleading**, failing to explain the key properties that make our models effective. The Universal Approximation Theorem, for example, guarantees representational power but does so via a construction that implies an exponential scaling that our models somehow avoid.
- And in yet other areas, our classical theories are almost **entirely silent**. They offer no framework to even begin explaining deep puzzles like the uncanny convergence of representations across vastly different models trained on the same data.

We are therefore faced with a collection of major empirical findings where our foundational theories are either contradicted, misleading, or simply absent. This theoretical vacuum creates an opportunity for a new perspective.

The program synthesis hypothesis offers such a perspective. It suggests we shift our view of what deep learning is fundamentally doing: from statistical **function fitting** to **program search**. The specific claim is that deep learning performs a search for simple programs that explain the data.

This shift in viewpoint may offer a way to make sense of the theoretical tensions we have outlined. If the learning process is a search for an efficient _program_ rather than an arbitrary function, then the circumvention of the curse of dimensionality is no longer so mysterious. If this search is guided by a strong simplicity bias, the unreasonable effectiveness of scaling becomes an expected outcome, rather than a paradox.

We will now turn to the well-known paradoxes of approximation, generalization, and convergence, and see how the program synthesis hypothesis accounts for each.

## **The paradox of approximation**

_(See also_ [_this post_](https://www.lesswrong.com/posts/gq9GR6duzcuxyxZtD/approximation-is-expensive-but-the-lunch-is-cheap) _for related discussion.)_

![](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/gq9GR6duzcuxyxZtD/ulhsq40yvefiumb90wbq)We can overcome the curse of dimensionality because real problems can be broken down into parts. When this happens sequentially (like the trees on the right) deep networks have an advantage. [Image source](https://www.lesswrong.com/posts/gq9GR6duzcuxyxZtD/approximation-is-expensive-but-the-lunch-is-cheap).

Before we even consider how a network learns or generalizes, there is a more basic question: how can a neural network, with a practical number of parameters, even _in principle_ represent the complex function it is trained on?

Consider the task of image classification. A function that takes a 1024x1024 pixel image (roughly one million input dimensions) and maps it to a single label like "cat" or "dog" is, _a priori_, an object of staggering high-dimensional complexity. Who is to say that a good approximation of this function even _exists_ within the space of functions that a neural network of a given size can express?

The textbook answer to this question is the **Universal Approximation Theorem (UAT)**. This theorem states that a neural network with a single hidden layer can, given enough neurons, approximate any continuous function to arbitrary accuracy. On its face, this seems to resolve the issue entirely.

A precise statement of the Universal Approximation Theorem

Let σ be a continuous, non-polynomial function. Then for every continuous function f from a compact subset of Rn to Rm, and some ε>0, we can choose the number of neurons k large enough such that there exists a network g with

supx∥f(x)−g(x)∥<ε

where g(x)=C⋅(σ∘(A⋅x+b)) for some matrices A∈Rk×n, b∈Rk, and C∈Rm×k.

See [here](https://en.wikipedia.org/wiki/Universal_approximation_theorem#Arbitrary-width_case) for a proof sketch. In plain English, this means that for any well-behaved target function f, you can always make a one-layer network g that is a "good enough" approximation, just by making the number of neurons k sufficiently large.

Note that the network here is a shallow one - the theorem doesn't even explain why you need _deep_ networks, an issue we'll return to when we talk about _depth separations_. In fact, one can prove theorems like this without even needing _neural networks_ at all - the theorem directly parallels the classic [Stone-Weierstrass theorem](https://en.wikipedia.org/wiki/Stone%E2%80%93Weierstrass_theorem) from analysis, which proves a similar statement for polynomials.

However, this answer is deeply misleading. The crucial caveat is the phrase "given enough neurons." A closer look at the proofs of the UAT reveals that for an arbitrary function, the number of neurons required scales _exponentially_ with the dimension of the input. This is the infamous **curse of dimensionality**. To represent a function on a one-megapixel image, this would require a catastrophically large number of neurons - more than there are atoms in the universe.

The UAT, then, is not a satisfying explanation. In fact, it's a mathematical restatement of a near-trivial fact: with exponential resources, one can simply memorize a function's behavior. The constructions used to prove the theorem are effectively building a continuous version of a lookup table. This is not an explanation for the success of deep learning; it is a proof that if deep learning had to deal with arbitrary functions, it would be hopelessly impractical.

This is not merely a weakness of the UAT's particular proof; it is a fundamental property of high-dimensional spaces. Classical results in approximation theory show that this exponential scaling is not just an _upper_ bound on what's needed, but a strict **lower bound**. These theorems prove that _any_ method that aims to approximate _arbitrary_ smooth functions is doomed to suffer the curse of dimensionality.

The parameter count lower bound

There are many results proving various lower bounds on the parameter count available in the literature under different technical assumptions.

A classic result from [DeVore, Howard, and Micchelli (1989)](https://gwern.net/doc/cs/algorithm/1989-devore.pdf) \[Theorem 4.2\] establishes a lower bound on the number of parameters n required by any continuous approximation scheme (including neural networks) to achieve an error ε over the space of all smooth functions in d dimensions. The number of parameters n must satisfy:

n≳ε−d/r

where r is a measure of the function's smoothness. To maintain a constant error ε as the dimension d increases, the number of parameters n must grow exponentially. This confirms that no clever trick can escape this fate _if the target functions are arbitrary_.

The real lesson of the Universal Approximation Theorem, then, is not that neural networks are powerful. The real lesson is that **if the functions we learn in the real world were arbitrary, deep learning would be impossible.** The empirical success of deep learning with a reasonable number of parameters is therefore a profound clue about the _nature of the problems themselves_: they must have structure.

The program synthesis hypothesis gives a name to this structure: **compositionality**. This is not a new idea. It is the foundational principle of computer science. To solve a complex problem, we do not write down a giant lookup table that specifies the output for every possible input. Instead, we write a **program**: we break the problem down hierarchically into a sequence of simple, reusable steps. Each step (like a logic gate in a circuit) is a tiny lookup table, and we achieve immense expressive power by composing them.

This matches what we see empirically in some deep neural networks via mechanistic interpretability. They appear to solve complex tasks by learning a compositional hierarchy of features. A vision model learns to detect edges, which are composed into shapes, which are composed into object parts (wheels, windows), which are finally composed into an object detector for a "car." The network is not learning a single, monolithic function; it is learning a program that breaks the problem down.

This parallel with classical computation offers an alternative perspective on the approximation question. While the UAT considers the case of arbitrary functions, a different set of results examines how well neural networks can represent functions that have this compositional, programmatic structure.

One of the most relevant results comes from considering _Boolean circuits_, which are a canonical example of programmatic composition. It is known that **feedforward neural networks can represent any program implementable by a polynomial-size Boolean circuit, using only a polynomial number of neurons.** This provides a different kind of guarantee than the UAT. It suggests that if a problem has an _efficient_ programmatic solution, then an _efficient_ neural network representation of that solution also exists.

This offers an explanation for how neural networks might evade the curse of dimensionality. Their effectiveness would stem not from an ability to represent _any_ high-dimensional function, but from their suitability for representing the tiny, structured subset of functions that have efficient programs. The problems seen in practice, from image recognition to language translation, appear to belong to this special class.

Why _compositionality_, specifically? Evidence from depth separation results.

The argument so far is that real-world problems must have some special "structure" to escape the curse of dimensionality, and that this structure is _program structure or compositionality_. But how can we be sure? Yes, approximation theory requires that we must have _something_ that differentiates our target functions from arbitrary smooth functions in order to avoid needing exponentially many parameters, but it does not specify _what_. The structure does not necessarily have to be compositionality; it could be something else entirely.

While there is no definitive proof, the literature on **depth separation theorems** provides evidence for the compositionality hypothesis. The logic is straightforward: if compositionality is the key, then an architecture that is restricted in its ability to compose operations should struggle. Specifically, one would expect that restricting a network's _depth -_ its capacity for sequential, step-by-step computation - should force it back towards exponential scaling for certain problems.

And this is what the theorems show.

These depth separation results, sometimes also called "no-flattening theorems," involve constructing families of functions that deep neural networks can represent with a polynomial number of parameters, but which shallow networks would require an _exponential_ number to represent. The literature contains a range of such functions, including [sawtooth functions](https://arxiv.org/abs/1602.04485), [certain polynomials](https://arxiv.org/abs/1705.05502), and [functions with hierarchical or modular substructures](https://arxiv.org/abs/1608.08225).

Individually, many of these examples are mathematical constructions, too specific to tell us much about realistic tasks on their own. But taken together, a pattern emerges. The functions where depth provides an exponential advantage are consistently those that are built "step-by-step." They have a sequential structure that deep networks can mirror. A deep network can compute an intermediate result in one layer and then feed that result into the next, effectively executing a multi-step computation.

A shallow network, by contrast, has no room for this kind of sequential processing. It must compute its output in a single, parallel step. While it can still perform "piece-by-piece" computation (which is what its _width_ allows), it cannot perform "step-by-step" computation. Faced with an inherently sequential problem, a shallow network is forced to simulate the entire multi-step computation at once. This can be highly inefficient, in the same way that simulating a sequential program on a highly parallel machine can sometimes require exponentially more resources.

This provides a parallel to classical complexity theory. The distinction between depth and width in neural networks mirrors the distinction between sequential (P) and parallelizable (NC) computation. Just as it is conjectured that some problems are inherently sequential and cannot be efficiently parallelized (the NC ≠ P conjecture), these theorems show that some functions are inherently deep and cannot be efficiently "flattened" into a shallow network.

## **The paradox of generalization**

_(See also_ [_this post_](https://www.lesswrong.com/s/WWx8sZ9tE9skptytH/p/uG7oJkyLBHEw3MYpT) _for related discussion.)_

![Bias–variance tradeoff - Wikipedia](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/iFymqTKHgftbzqMy7/kelygoxzbm6pgrcvp55j)![Overfitting - MATLAB & Simulink](https://res.cloudinary.com/lesswrong-2-0/image/upload/f_auto,q_auto/v1/mirroredImages/iFymqTKHgftbzqMy7/gzkcaz6ux4rzjscjlasv)

Perhaps the most jarring departure from classical theory comes from how deep learning models generalize. A learning algorithm is only useful if it can perform well on new, unseen data. The central question of statistical learning theory is: what are the conditions that allow a model to generalize?

The classical answer is the **bias-variance tradeoff**. The theory posits that a model's error can be decomposed into two main sources:

- **Bias:** Error from the model being too simple to capture the underlying structure of the data ( _underfitting_).
- **Variance:** Error from the model being too sensitive to the specific training data it saw, causing it to fit noise ( _overfitting_).

According to this framework, learning is a delicate balancing act. The practitioner's job is to carefully choose a model of the "right" complexity - not too simple, not too complex -to land in a "Goldilocks zone" where both bias and variance are low. This view is reinforced by principles like the "no free lunch" theorems, which suggest there is no universally good learning algorithm, only algorithms whose inductive biases are carefully chosen by a human to match a specific problem domain.

The clear prediction from this classical perspective is that naively increasing a model's capacity (e.g., by adding more parameters) far beyond what is needed to fit the training data is a recipe for disaster. Such a model should have catastrophically high variance, leading to rampant overfitting and poor generalization.

And yet, perhaps the single most important empirical finding in modern deep learning is that this prediction is completely wrong. The "[bitter lesson](http://www.incompleteideas.net/IncIdeas/BitterLesson.html)," as Rich Sutton calls it, is that the most reliable path to better performance is to **scale up compute and model size**, sometimes far into the regime where the model can easily memorize the entire training set. This goes beyond a minor deviation from theoretical predictions: it is a direct contradiction of the theory's core prescriptive advice.

This brings us to a second, deeper puzzle, first highlighted by [Zhang et al. (2017)](https://arxiv.org/abs/1611.03530). The authors conduct a simple experiment:

- They train a standard vision model on a real dataset (e.g., CIFAR-10) and confirm that it generalizes well.
- They then train the _exact same model_, with the exact same architecture, optimizer, and regularization, on a corrupted version of the dataset where the labels have been completely randomized.

The network is expressive enough that it is able to achieve near-zero training error on the randomized labels, perfectly memorizing the nonsensical data. As expected, its performance on a test set is terrible - it has learned nothing generalizable.

The paradox is this: why did the _same exact model_ generalize well on the real data? Classical theories often tie a model's generalization ability to its "capacity" or "complexity," which is a fixed property of its architecture related to its expressivity. But this experiment shows that generalization is not a static property of the model. It is a dynamic outcome of the interaction between the model, the learning algorithm, and the **structure of the data itself**. The very same network that is _completely capable_ of memorizing random noise somehow "chooses" to find a generalizable solution when trained on data with real structure. Why?

The program synthesis hypothesis offers a coherent explanation for both of these paradoxes.

First, **why does scaling work?** The hypothesis posits that learning is a _search_ through some space of programs, guided by a strong simplicity bias. In this view, adding more parameters is analogous to expanding the search space (e.g., allowing for longer or more complex programs). While this does increase the model's capacity to represent overfitting solutions, the simplicity bias acts as a powerful regularizer. The learning process is not looking for _any_ program that fits the data; it is looking for the _simplest_ program. Giving the search more resources (parameters, compute, data) provides a better opportunity to find the simple, generalizable program that corresponds to the true underlying structure, rather than settling for a more complex, memorizing one.

Second, **why does generalization depend on the data's structure?** This is a natural consequence of a simplicity-biased program search.

- When trained on **real data**, there exists a short, simple program that explains the statistical regularities (e.g., "cats have pointy ears and whiskers"). The simplicity bias of the learning process finds this program, and because it captures the true structure, it generalizes well.
- When trained on **random labels**, no such simple program exists. The only way to map the given images to the random labels is via a long, complicated, high-complexity program (effectively, a lookup table). Forced against its inductive bias, the learning algorithm eventually finds such a program to minimize the training loss. This solution is pure memorization and, naturally, fails to generalize.

If one assumes something like the program synthesis hypothesis is true, the phenomenon of data-dependent generalization is not so surprising. A model's ability to generalize is not a fixed property of its architecture, but a property of the **program it learns**. The model finds a simple program on the real dataset and a complex one on the random dataset, and the two programs have very different generalization properties.And there is some evidence that the mechanism behind generalization is not so unrelated to the other empirical phenomena we have discussed. We can see this in the **grokking** setting discussed earlier. Recall the transformer trained on modular addition:

- Initially, the model learns a **memorization-based program**. It achieves 100% accuracy on the training data, but its test accuracy is near zero. This is analogous to learning the "random label" dataset - a complex, non-generalizing solution.
- After extensive further training, driven by a regularizer that penalizes complexity (weight decay), the model's internal solution undergoes a "phase transition." It discovers the **Fourier-based algorithm** for modular addition.
- Coincident with the discovery of this algorithmic program (or rather, the removal of the memorization program, which occurs slightly later), test accuracy abruptly jumps to 100%.

The sudden increase in generalization appears to be the direct consequence of the model replacing a complex, overfitting solution with a simpler, algorithmic one. In this instance, generalization is achieved through the synthesis of a different, more efficient program.

## **The paradox of convergence**

When we ask a neural network to solve a task, we specify what task we'd like it to solve, but not _how_ it should solve the task - the purpose of _learning_ is for it to find strategies on its own. We define a loss function and an architecture, creating a space of possible functions, and ask the learning algorithm to find a good one by minimizing the loss. Given this freedom, and the high-dimensionality of the search space, one might expect the solutions found by different models - especially those with different architectures or random initializations - to be highly diverse.

Instead, what we observe empirically is a strong tendency towards **convergence**. This is most directly visible in the phenomenon of [**representational alignment**](https://arxiv.org/abs/2310.13018). This alignment is remarkably robust:

- It holds across different training runs of the same architecture, showing that the final solution is not a sensitive accident of the random seed.
- More surprisingly, it holds across different architectures. The internal activations of a Transformer and a CNN trained on the same vision task, for example, can often be mapped to one another with a simple linear transformation, suggesting they are learning not just similar input-output behavior, but similar intermediate computational steps.
- It even holds in some cases across modalities. Models like CLIP, trained to associate images with text, learn a shared representation space where the vector for a photograph of a dog is close to the vector for the phrase "a photo of a dog," indicating convergence on a common, abstract conceptual structure.

The mystery deepens when we observe parallels to biological systems. The [Gabor](https://en.wikipedia.org/wiki/Gabor_filter)-like filters that emerge in the early layers of vision networks, for instance, are strikingly similar to the receptive fields of neurons in the V1 area of the primate visual cortex. It appears that evolution and stochastic gradient descent, two very different optimization processes operating on very different substrates, have converged on similar solutions when exposed to the same statistical structure of the natural world.

One way to account for this is to hypothesize that the models are not navigating some undifferentiated space of arbitrary functions, but are instead homing in on a sparse set of highly effective programs that solve the task. If, following the physical Church-Turing thesis, we view the natural world as having a true, computable structure, then an effective learning process could be seen as a search for an algorithm that approximates that structure. In this light, convergence is not an accident, but a sign that different search processes are discovering similar objectively good solutions, much as different engineering traditions might independently arrive at the arch as an efficient solution for bridging a gap.

This hypothesis - that learning is a search for an optimal, objective program - carries with it a strong implication: the search process must be a **general-purpose** one, capable of finding such programs without them being explicitly encoded in its architecture. As it happens, an independent, large-scale trend in the field provides a great deal of data on this very point.

Rich Sutton's "[**bitter lesson**](http://www.incompleteideas.net/IncIdeas/BitterLesson.html)" describes the consistent empirical finding that long-term progress comes from scaling general learning methods, rather than from encoding specific human domain knowledge. The old paradigm, particularly in fields like computer vision, speech recognition, or game playing, involved painstakingly hand-crafting systems with significant prior knowledge. For years, the state of the art relied on complex, hand-designed feature extractors like SIFT and HOG, which were built on human intuitions about what aspects of an image are important. The role of learning was confined to a relatively simple classifier that operated on these pre-digested features. The underlying assumption was that the search space was too difficult to navigate without strong human guidance.

The modern paradigm of deep learning has shown this assumption to be incorrect. Progress has come from abandoning these handcrafted constraints in favor of training general, end-to-end architectures with the brute force of data and compute. This consistent triumph of general learning over encoded human knowledge is a powerful indicator that the search process we are using is, in fact, general-purpose. It suggests that the learning algorithm itself, when given a sufficiently flexible substrate and enough resources, is a more effective mechanism for discovering relevant features and structure than human ingenuity.

This perspective helps connect these phenomena, but it also invites us to refine our initial picture. First, the notion of a single "optimal program" may be too rigid. It is possible that what we are observing is not convergence to a single point, but to a narrow subset of similarly structured, highly-efficient programs. The models may be learning different but algorithmically related solutions, all belonging to the same family of effective strategies.

Second, it is unclear whether this convergence is purely a property of the problem's solution space, or if it is also a consequence of our search algorithm. Stochastic gradient descent is not a neutral explorer. The implicit biases of stochastic optimization, when navigating a highly over-parameterized loss landscape, may create powerful channels that funnel the learning process toward a specific _kind_ of simple, compositional solution. Perhaps all roads do not lead to Rome, but the roads to Rome are the fastest. The convergence could therefore be a clue about the nature of our learning dynamics themselves - that they possess a strong, intrinsic preference for a particular class of solutions.

Viewed together, these observations suggest that the space of effective solutions for real-world tasks is far smaller and more structured than the space of possible models. The phenomenon of convergence indicates that our models are finding this structure. The bitter lesson suggests that our learning methods are general enough to do so. The remaining questions point us toward the precise nature of that structure and the mechanisms by which our learning algorithms are so remarkably good at finding it.

# **The path forward**

If you've followed the argument this far, you might already sense where it becomes difficult to make precise. The mechanistic interpretability evidence shows that networks _can_ implement compositional algorithms. The indirect evidence suggests this connects to why they generalize, scale, and converge. But "connects to" is doing a lot of work. What would it actually mean to say that deep learning _is_ some form of program synthesis?

Trying to answer this carefully leads to two problems. The claim "neural networks learn programs" seems to require saying what a program even _is_ in a space of continuous parameters. It also requires explaining how gradient descent could find such programs efficiently, given what we know about the intractability of program search.

These are the kinds of problems where the difficulty itself is informative. Each has a specific shape - what you need to think about, what a resolution would need to provide. I focus on them deliberately: that shape is what eventually pointed me toward specific mathematical tools I wouldn't have considered otherwise.

This is also where the post will shift register. The remaining sections sketch the structure of these problems and gesture at why certain mathematical frameworks (singular learning theory, algebraic geometry, etc) might become relevant. I won't develop these fully here - that requires machinery far beyond the scope of a single blog post - but I want to show why you'd need to leave shore at all, and what you might find out in open water.

## **The representation problem**

The program synthesis hypothesis posits a relationship between two fundamentally different kinds of mathematical objects.

On one hand, we have **programs**. A program is a discrete and symbolic object. Its identity is defined by its compositional structure - a graph of distinct operations. A small change to this structure, like flipping a comparison or replacing an addition with a subtraction, can create a completely different program with discontinuous, global changes in behavior. The space of programs is discrete.

On the other hand, we have **neural networks**. A neural network is defined by its **parameter space**: a continuous vector space of real-valued weights. The function a network computes is a smooth (or at least piecewise-smooth) function of these parameters. This smoothness is the essential property that allows for learning via gradient descent, a process of infinitesimal steps along a continuous loss landscape.

This presents a seeming type mismatch: **how can a continuous process in a continuous parameter space give rise to a discrete, structured program?**

The problem is deeper than it first appears. To see why, we must first be precise about what we mean when we say a network has "learned a program." It cannot simply be about the input-output function the network computes. A network that has perfectly memorized a lookup table for modular addition computes the same function on a finite domain as a network that has learned the general, trigonometric algorithm. Yet we would want to say, emphatically, that they have learned different programs. The program is not just the _function_; it is the underlying **mechanism**.

Thus the notion must depend on parameters, and not just functions, presenting a further conceptual barrier. To formalize the notion of "mechanism," a natural first thought might be to partition the continuous parameter space into discrete regions. In this picture, all the parameter vectors within a region WA would correspond to the same program A, while vectors in a different region WB would correspond to program B. But this simple picture runs into a subtle and fatal problem: the very smoothness that makes gradient descent possible works to dissolve any sharp boundaries between programs.

Imagine a continuous path in parameter space from a point wA∈WA (which clearly implements program A) to a point wB∈WB (which clearly implements program B). Imagine, say, that A has some extra subroutine that B does not. Because the map from parameters to the function is smooth, the network's behavior must change continuously along this path. At what exact point on this path did the mechanism switch from A to B? Where did the new subroutine get added? There is no canonical place to draw a line. A sharp boundary would imply a discontinuity that the smoothness of the map from parameters to functions seems to forbid.

This is not so simple a problem, and it is worth spending some time thinking about how you might try to resolve it to appreciate that.

What this suggests, then, is that for the program synthesis hypothesis to be a coherent scientific claim, it requires something that does not yet exist: a formal, geometric notion of a _space of programs_. This is a rather large gap to fill, and in some ways, this entire post is my long-winded way of justifying such an ambitious mathematical goal.

I won't pretend that my collaborators and I don't have [our](https://arxiv.org/abs/2207.10871)[\[14\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnlzj33x1q4yp)[own](https://arxiv.org/abs/2502.08911)[ideas](https://arxiv.org/abs/2504.08075) about how to resolve this, but the mathematical sophistication required jumps substantially, and they would probably require their own full-length post to do justice. For now, I will just gesture at some clues which I think point in the right direction.

The first is the phenomenon of _degeneracies_[\[15\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fn5hsrpicn3vp). Consider, for instance, _dead neurons_, whose incoming weights and activations are such that the neurons never fires for any input. A neural network with dead neurons acts like a smaller network with those dead neurons removed. This gives a mechanism for neural networks to change their "effective size" in a parameter-dependent way, which is required in order to e.g. dynamically add or remove a new subroutine depending on where you are in parameter space, as in our example above. In fact dead neurons are just one example in a whole [zoo of degeneracies](https://far.in.net/mthesis.pdf) with similar effects, which seem incredibly pervasive in neural networks.

It is worth mentioning that the present picture is now highly suggestive of a specific branch of math known as _algebraic geometry_. Algebraic geometry (in particular, singularity theory) systematically studies these degeneracies, and further provides a bridge between _discrete_ structure (algebra) and _continuous_ structure (geometry), exactly the type of connection we identified as necessary for the program synthesis hypothesis[\[16\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnfukshjhtc2n). Furthermore, _singular learning theory_ tells us how these degeneracies control the loss landscape and the learning process (classically, only in the _Bayesian_ setting, a limitation we discuss in the next section). There is much more that can be said here, but I leave it for the future to treat this material properly.

## **The search problem**

There’s another problem with this story. Our hypothesis is that deep learning is performing some version of program _synthesis_. That means that we not only have to explain how programs get _represented_ in neural networks, we also need to explain how they get _learned_. There are two subproblems here.

- First, how can deep learning even implement the needed inductive biases? For deep learning algorithms to be implementing something analogous to Solomonoff induction, they must be able to implicitly follow inductive biases which depend on the program structure, like simplicity bias. That is, the optimization process must somehow be aware of the program structure in order to favor some types of programs (e.g. shorter programs) over others. The optimizer must “see” the program structure of parameters.
- Second, deep learning works in practice, using a reasonable amount of computational resources; meanwhile, even the most efficient versions of Solomonoff induction like speed induction run in exponential time or worse[\[5\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnl2yn9dinv). If deep learning is efficiently performing some version of program synthesis analogous to Solomonoff induction, that means it has implicitly managed to do what we could not figure out how to do explicitly - its efficiency must be due to some insight which we do not yet know. Of course, we know part of the answer: SGD only needs local information in order to optimize, instead of brute-force global search as one does with Bayesian learning. But then the mystery becomes a well-known one: why does myopic search like SGD converge to globally good solutions?

Both of these are questions about the optimization process. It is not obvious at all how local optimizers like SGD would be able to perform something like Solomonoff induction, let alone _far more efficiently_ than we historically ever figured out for (versions of) Solomonoff induction itself. This is a difficult question, but I will attempt to point towards research which I believe can answer these questions.

The optimization process can depend on many things, a priori: choice of optimizer, regularization, dropout, step size, etc. But we can note that deep learning is able to work somewhat successfully (albeit sometimes with degraded performance) across wide ranges of choices of these variables. It does not seem like the choice of AdamW vs SGD matters nearly as much as the choice to do gradient-based learning in the first place. In other words, I believe these variables may affect efficiency, but I doubt they are fundamental to the explanation of why the optimization process can possibly succeed.

Instead, there is one common variable here which appears to determine the vast majority of the behavior of stochastic optimizers: the loss function. Optimizers like SGD take every gradient step according to a minibatch-loss function[\[17\]](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnlc0m4rnjr2d) like mean-squared error:

dwdt=−τdLdwL(w)=1nn∑i=1(yi−fw(xi))2

where w is the parameter vector, fw is the input/output map of the model on parameter w,(xi,yi) are the n training examples & labels, and τ is the learning rate.

In the most common versions of supervised learning, we can focus even further. The loss function itself can be decomposed into two effects: the parameter-function map w↦fw, and the target distribution. The overall loss function can be written as a composition of the parameter-function map and some statistical distance to the target distribution, e.g. for mean-squared error:

L(w)=ℓ∘f

where ℓ(g)=1/n∑ni=1(yi−g(xi))2.

Note that the statistical distance ℓ(g) here is a fairly simple object. Almost always the statistical distance here is (on function space) convex and with relatively simple functional form; further, it is the same distance one would use across many different architectures, including ones which do not achieve the remarkable performance of neural networks (e.g. polynomial approximation). Therefore one expects the question of learnability and inductive biases to largely come down to the parameter-function map fw rather than the (function-space) loss function ℓ(g).

If the above reasoning is correct, that means that in order to understand how SGD is able to potentially perform some kind of program synthesis, we merely need to understand properties of the parameter-function map. This would be a substantial simplification. Further, this relates learning dynamics to our earlier representation problem: the parameter-function map is precisely the same object responsible for the mystery discussed in the representation section.

This is not an airtight argument - it depends on the empirical question of whether one can ignore (or treat as second-order effects) other optimization details besides the loss function, and whether the handwave-y argument for the importance of the parameter-function map over the (function-space) loss is solid.

Even if one assumes this argument is valid, we have merely located the mystery, not resolved it. The question remains: what properties of the parameter-function map make targets learnable? At this point the reasoning becomes more speculative, but I will sketch some ideas.

The representation section concerned what structure the map encodes at each point in parameter space. Learnability appears to depend on something further: the structure of paths between points. Convexity of function-space loss implies that paths which are sufficiently straight in function space are barrier-free - roughly, if the endpoint is lower loss, the entire path is downhill. So the question becomes: which function-space paths does the map provide?

The same architectures successfully learn many diverse real-world targets. Whatever property of the map enables this, it must be relatively universal - not tailored to specific targets. This naturally leads us to ask: in what cases does the parameter-function map provide direct-enough paths to targets with certain structure, and characterizing what "direct enough" means.

This connects back to the representation problem. If the map encodes some notion of program structure, then path structure in parameter space induces relationships between programs - which programs are "adjacent," which are reachable from which. The representation section asks how programs are encoded as points; learnability asks how they are connected as paths. These are different aspects of the same object.

One hypothesis: compositional relationships between programs might correspond to some notion of “path adjacency” defined by the parameter-function map. If programs sharing structure are nearby - reachable from each other via direct paths - and if simpler programs lie along paths to more complex ones, then efficiency, simplicity bias, and empirically observed stagewise learning would follow naturally. Gradient descent would build incrementally rather than search randomly; the enumeration problem that dooms Solomonoff would dissolve into traversal.

This is speculative and imprecise. But there's something about the shape of what's needed that feels mathematically natural. The representation problem asks for a correspondence at the level of objects: strata in parameter space corresponding to programs. The search problem asks for something stronger - that this correspondence extends to _paths_. Paths in parameter space (what gradient descent traverses) should correspond to some notion of relationship or transition between programs.

This is a familiar move in higher mathematics (sometimes formalized by category theory): once you have a correspondence between two kinds of objects, you ask whether it extends to the relationships between those objects. It is especially familiar (in fields like higher category theory) to ask these kinds of questions when the "relationships between objects" take the form of _paths_ in particular. I don't claim that existing machinery from these fields applies directly, and certainly not given the (lack of) detail I've provided in this post. But the question is suggestive enough to investigate: what should "adjacency between programs" mean? Does the parameter-function map induce or preserve such structure? And if so, what does this predict about learning dynamics that we could check empirically?

# **Appendix**

## **Related work**

The majority of the ideas in this post are not individually novel; I see the core value proposition as synthesizing them together in one place. The ideas I express here are, in my experience, very common among researchers at frontier labs, researchers in mechanistic interpretability, some researchers within science of deep learning, and others. In particular, the core hypothesis that deep learning is performing some tractable version of Solomonoff induction is not new, and has been [written](https://www.lesswrong.com/posts/LxCeyxH3fBSmd4oWB/deep-learning-is-cheap-solomonoff-induction-1)[about](https://www.amazon.science/blog/solomonic-learning-large-language-models-and-the-art-of-induction)[many](https://x.com/johnschulman2/status/1741178475946602979)[times](https://www.lesswrong.com/posts/MznxnYCtHZbtDxJuh/approximating-solomonoff-induction). (However, I would not consider it to be a popular or accepted opinion within the machine learning field at large.) Personally, I have considered a version of this hypothesis for around three years. With this post, I aim to share a more comprehensive synthesis of the evidence for this hypothesis, as well as point to specific research directions for formalizing this idea.

Below is an incomplete list of what is known and published in various areas:

**Existing comparisons between deep learning and program synthesis.** The ideas surrounding Solomonoff induction have been highly motivating for many early AGI-focused researchers. Shane Legg (DeepMind cofounder) wrote his [PhD thesis](http://www.vetta.org/documents/Machine_Super_Intelligence.pdf) on Solomonoff induction; John Schulam (OpenAI cofounder) discusses the connection to deep learning explicitly [here](https://x.com/johnschulman2/status/1741178475946602979); Ilya Sutskever (OpenAI cofounder) has been giving [talks](https://x.com/mhutter42/status/1691866331602186466) on related ideas. There are a handful [of](https://www.lesswrong.com/posts/LxCeyxH3fBSmd4oWB/deep-learning-is-cheap-solomonoff-induction-1)[places](https://x.com/johnschulman2/status/1741178475946602979)[one](https://www.lesswrong.com/posts/MznxnYCtHZbtDxJuh/approximating-solomonoff-induction)[can](https://blog.wadan.co.jp/en/tech/solomonoff-induction-compression-generalization) find a hypothesized connection between deep learning and Solomonoff induction stated explicitly, though I do not believe any of these were the first to do so. My personal experience is that such intuitions are fairly common among e.g. people working at frontier labs, even if they are not published in writing. I am not sure who had the idea first, and suspect it was arrived at independently multiple times.

**Feature learning.** It would not be accurate to say that the average ML researcher views deep learning as a _complete_ black-box algorithm; it is well-accepted and uncontroversial that deep neural networks are able to extract "features" from the task which they use to perform well. However, it is a step beyond to claim that these features are actually extracted and composed in some mechanistic fashion resembling a computer program.

**Compositionality, hierarchy, and modularity.** My informal notion of "programs" here is quite closely related to compositionality. It is a fairly well-known hypothesis that supervised learning performs well due to compositional/hierarchical/modular structure in the model and/or the target task. This is particularly prominent [within approximation theory](https://cdn.aaai.org/ojs/10913/10913-13-14441-1-2-20201228.pdf) (especially the literature on depth separations) as an explanation for the issues I highlighted in the "paradox of approximation" section.

**Mechanistic interpretability.** The (implicit) underlying premise of the field of _mechanistic interpretability_ is that one can understand the internal mechanistic (read: program-like) structure responsible for a network's outputs. Mechanistic interpretability is responsible for discovering a significant number of examples of this type of structure, which I believe constitutes the single strongest evidence for the program synthesis hypothesis. I discuss a few case studies of this structure in the post, but there are possibly hundreds more examples which I did not cover, from the many papers within the field. A recent review can be found [here](https://arxiv.org/abs/2404.14082).

**Singular learning theory.** In the “path forward” section, I highlight a possible role of degeneracies in controlling some kind of effective program structure. In some way (which I have gestured at but not elaborated on), the ideas presented in this post can be seen as motivating singular learning theory as a means to formally ground these ideas and produce practical tools to operationalize them. This is most explicit within a [line of work](https://arxiv.org/abs/2504.08075) within singular learning theory that attempts to precisely connect program synthesis with the singular geometry of a (toy) learning machine.

01. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefz8jpod2itgo)**


    From the [GPT-4.5 launch discussion, 38:46](https://www.youtube.com/watch?v=6nJZopACRuQ&t=2326s).

02. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref9y7nox8uh2)**


    From his [PhD thesis](http://www.vetta.org/documents/Machine_Super_Intelligence.pdf), pages 23-24.

03. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref9w6g132qlp)**


    Together with independent contributions by Kolmogorov, Chaitin, and Levin.

04. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefjxst5sv8a9)**


    One must be careful, as some commonly stated "proofs" of this optimality are somewhat tautological. These typically go roughly something like: under the assumption that the data generating process has low Kolmogorov complexity, then Solomonoff induction is optimal. This is of course completely circular, since we have, in effect, assumed from the start that the inductive bias of Solomonoff induction is correct. Better proofs of this fact instead show a regret bound: on _any_ sequence, Solomonoff induction's cumulative loss is at most a constant worse than any computable predictor - where the constant depends on the complexity of the _competing predictor_, not the sequence. This is a frequentist guarantee requiring no assumptions about the data source. See in particular Section 3.3.2 and Theorem 3.3 of [this PhD thesis](https://philsci-archive.pitt.edu/14486/). Thanks to Cole Wyeth for pointing me to this argument.

05. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefl2yn9dinv)**


    See [this paper](https://arxiv.org/abs/1604.03343).

06. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref6vd5zchhq54)**


    Depending on what one means by "protein folding," one can debate whether the problem has truly been solved; for instance, the problem of how proteins fold _dynamically_ over time is still open AFAIK. See [this fairly well-known blog post](https://moalquraishi.wordpress.com/2020/12/08/alphafold2-casp14-it-feels-like-ones-child-has-left-home/) by molecular biologist Mohammed AlQuraishi for more discussion, and why he believes calling AlphaFold a "solution" can be appropriate despite the caveats.

07. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefiejpex45eha)**


    In fact, the solution can be seen as a representation-theoretic algorithm for the group of integers under addition mod P (the cyclic group CP). [Follow-up](https://arxiv.org/abs/2302.03025)[papers](https://arxiv.org/abs/2312.06581) demonstrated that neural networks also learn interpretable representation-theoretic algorithms for more general groups than cyclic groups.

08. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefb5ms35mh16)**


    For what it's worth, in this specific case, we do know what must be driving the process, if not the training loss: the regularization / weight decay. In the case of grokking, we do have [decent understanding](https://arxiv.org/abs/2210.01117) of how weight decay leads the training to prefer the generalizing solution. However, this explanation is limited in various ways, and it unclear how far it generalizes beyond this specific setting.

09. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnreffqn67eo6jo5)**


    To be clear, one can still apply existing mechanistic interpretability tools to real language models and get productive results. But the results typically only manage to explain a small portion of the network, and in a way which is (in my opinion) less clean and convincing than e.g. [Olah et al. (2020)](https://distill.pub/2020/circuits/zoom-in/)'s reverse-engineering of InceptionV1.

10. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref8byhvyt3kqe)**


    This phrase is often abused - for instance, if you show up to court with no evidence, I can reasonably infer that no good evidence for your case exists. This is a gap between _logical_ and _heuristic/Bayesian_ reasoning. In the real world, if evidence for a proposition exists, it usually can and will be found (because we care about it), so you can interpret the absence of evidence for a proposition as suggesting that the proposition is false. However, in this case, I present a _specific reason_ why one should not expect to see evidence _even if_ the proposition in question is true.

11. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefguz89j1a968)**


    Many interpretability researchers specifically believe in the [_linear representation hypothesis_](https://arxiv.org/abs/2311.03658), that the variables of this program structure ("features") correspond to linear directions in activation space, or the stronger [_superposition hypothesis_](https://transformer-circuits.pub/2022/toy_model/index.html), that such directions form a sparse overbasis for activation space. One must be careful in interpreting these hypotheses as there are different operationalizations within the community; in my opinion, the more sophisticated versions are far more plausible than naive versions (thank you to Chris Olah for a helpful conversation here). Presently, I am skeptical that linear representations give [the most prosaic description](https://transformer-circuits.pub/2025/linebreaks/index.html) of a model's behavior or that this will be sufficient for complete reverse-engineering, but believe that the hypothesis is pointing at something real about models, and tools like SAEs can be helpful as long as one is aware of their limitations.

12. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref969wylfycf)**


    See for instance the results of [these](https://arxiv.org/abs/2305.08746)[papers](https://arxiv.org/abs/2310.07711), where the authors incentivize spatial modularity with an additional regularization term. The authors interpret this as _incentivizing modularity_, but I would interpret it as _incentivizing existing modularity to come to the surface_.

13. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefc45j78nx35)**


    From [Dwarkesh Patel's podcast, 13:05](https://www.youtube.com/watch?v=Nlkk3glap_U&t=785s).

14. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnreflzj33x1q4yp)**


    The credit for these ideas should really go to Dan Murfet, as well as his current/former students including Will Troiani, James Clift, Rumi Salazar, and Billy Snikkers.

15. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref5hsrpicn3vp)**


    Let f(x\|w) denote the output of the model on input x with parameters w. Formally, we say that a point in parameter space w∈W is _degenerate_ or _singular_ if there exists a tangent vector v∈TW such that the directional derivative ∇vf(x\|w)=0 for all x. In other words, moving in some direction in parameter space doesn't change the behavior of the model (up to first order).

16. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnreffukshjhtc2n)**


    This is not as alien as it may seem. Note that this provides a perspective which connects nicely with both neural networks and classical computation. First consider, for instance, that the gates of a Boolean circuit literally define a system of equations over F2, whose solution set is an algebraic variety over F2. Alternatively, consider that a neural network with polynomial (or analytic) activation function defines a system of equations over R, whose vanishing set is an algebraic (respectively, analytic) variety over R. Of course this goes only a small fraction of the way to closing this gap, but one can start to see how this becomes plausible.

17. **[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnreflc0m4rnjr2d)**


    A frequent perspective is to write this minibatch-loss in terms of its mean (population) value plus some noise term. That is, we think of optimizers like SGD as something like “gradient descent plus noise.” This is quite similar to mathematical models like overdamped Langevin dynamics, though note that the noise term may not be Gaussian as in Langevin dynamics. It is an open question whether the convergence of neural network training is due to the population term or the noise term. (Note that this is a separate question as to whether the generalization / inductive biases of SGD-trained neural networks is due to the population term or the noise term.) I am tentatively of the belief (somewhat controversially) that both convergence and inductive bias is due to structure in the population loss rather than the noise term, but explaining my reasoning here is a bit out of scope.


![](https://www.lesswrong.com/reactionImages/nounproject/llm-smell.svg)

![](https://www.lesswrong.com/reactionImages/nounproject/type-text.svg)

![](https://www.lesswrong.com/reactionImages/nounproject/check.svg)![](https://www.lesswrong.com/reactionImages/nounproject/bullseye.svg)

1.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefz8jpod2itgo)**

From the [GPT-4.5 launch discussion, 38:46](https://www.youtube.com/watch?v=6nJZopACRuQ&t=2326s).

2.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref9y7nox8uh2)**

From his [PhD thesis](http://www.vetta.org/documents/Machine_Super_Intelligence.pdf), pages 23-24.

3.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref9w6g132qlp)**

Together with independent contributions by Kolmogorov, Chaitin, and Levin.

4.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefjxst5sv8a9)**

One must be careful, as some commonly stated "proofs" of this optimality are somewhat tautological. These typically go roughly something like: under the assumption that the data generating process has low Kolmogorov complexity, then Solomonoff induction is optimal. This is of course completely circular, since we have, in effect, assumed from the start that the inductive bias of Solomonoff induction is correct. Better proofs of this fact instead show a regret bound: on _any_ sequence, Solomonoff induction's cumulative loss is at most a constant worse than any computable predictor - where the constant depends on the complexity of the _competing predictor_, not the sequence. This is a frequentist guarantee requiring no assumptions about the data source. See in particular Section 3.3.2 and Theorem 3.3 of [this PhD thesis](https://philsci-archive.pitt.edu/14486/). Thanks to Cole Wyeth for pointing me to this argument.

5.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefl2yn9dinv)**

See [this paper](https://arxiv.org/abs/1604.03343).

6.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref6vd5zchhq54)**

Depending on what one means by "protein folding," one can debate whether the problem has truly been solved; for instance, the problem of how proteins fold _dynamically_ over time is still open AFAIK. See [this fairly well-known blog post](https://moalquraishi.wordpress.com/2020/12/08/alphafold2-casp14-it-feels-like-ones-child-has-left-home/) by molecular biologist Mohammed AlQuraishi for more discussion, and why he believes calling AlphaFold a "solution" can be appropriate despite the caveats.

7.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefiejpex45eha)**

In fact, the solution can be seen as a representation-theoretic algorithm for the group of integers under addition mod P (the cyclic group CP). [Follow-up](https://arxiv.org/abs/2302.03025)[papers](https://arxiv.org/abs/2312.06581) demonstrated that neural networks also learn interpretable representation-theoretic algorithms for more general groups than cyclic groups.

8.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefb5ms35mh16)**

For what it's worth, in this specific case, we do know what must be driving the process, if not the training loss: the regularization / weight decay. In the case of grokking, we do have [decent understanding](https://arxiv.org/abs/2210.01117) of how weight decay leads the training to prefer the generalizing solution. However, this explanation is limited in various ways, and it unclear how far it generalizes beyond this specific setting.

9.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnreffqn67eo6jo5)**

To be clear, one can still apply existing mechanistic interpretability tools to real language models and get productive results. But the results typically only manage to explain a small portion of the network, and in a way which is (in my opinion) less clean and convincing than e.g. [Olah et al. (2020)](https://distill.pub/2020/circuits/zoom-in/)'s reverse-engineering of InceptionV1.

10.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref8byhvyt3kqe)**

This phrase is often abused - for instance, if you show up to court with no evidence, I can reasonably infer that no good evidence for your case exists. This is a gap between _logical_ and _heuristic/Bayesian_ reasoning. In the real world, if evidence for a proposition exists, it usually can and will be found (because we care about it), so you can interpret the absence of evidence for a proposition as suggesting that the proposition is false. However, in this case, I present a _specific reason_ why one should not expect to see evidence _even if_ the proposition in question is true.

11.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefguz89j1a968)**

Many interpretability researchers specifically believe in the [_linear representation hypothesis_](https://arxiv.org/abs/2311.03658), that the variables of this program structure ("features") correspond to linear directions in activation space, or the stronger [_superposition hypothesis_](https://transformer-circuits.pub/2022/toy_model/index.html), that such directions form a sparse overbasis for activation space. One must be careful in interpreting these hypotheses as there are different operationalizations within the community; in my opinion, the more sophisticated versions are far more plausible than naive versions (thank you to Chris Olah for a helpful conversation here). Presently, I am skeptical that linear representations give [the most prosaic description](https://transformer-circuits.pub/2025/linebreaks/index.html) of a model's behavior or that this will be sufficient for complete reverse-engineering, but believe that the hypothesis is pointing at something real about models, and tools like SAEs can be helpful as long as one is aware of their limitations.

12.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref969wylfycf)**

See for instance the results of [these](https://arxiv.org/abs/2305.08746)[papers](https://arxiv.org/abs/2310.07711), where the authors incentivize spatial modularity with an additional regularization term. The authors interpret this as _incentivizing modularity_, but I would interpret it as _incentivizing existing modularity to come to the surface_.

13.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefc45j78nx35)**

From [Dwarkesh Patel's podcast, 13:05](https://www.youtube.com/watch?v=Nlkk3glap_U&t=785s).

14.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnreflzj33x1q4yp)**

The credit for these ideas should really go to Dan Murfet, as well as his current/former students including Will Troiani, James Clift, Rumi Salazar, and Billy Snikkers.

15.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnref5hsrpicn3vp)**

Let f(x\|w) denote the output of the model on input x with parameters w. Formally, we say that a point in parameter space w∈W is _degenerate_ or _singular_ if there exists a tangent vector v∈TW such that the directional derivative ∇vf(x\|w)=0 for all x. In other words, moving in some direction in parameter space doesn't change the behavior of the model (up to first order).

16.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnreffukshjhtc2n)**

This is not as alien as it may seem. Note that this provides a perspective which connects nicely with both neural networks and classical computation. First consider, for instance, that the gates of a Boolean circuit literally define a system of equations over F2, whose solution set is an algebraic variety over F2. Alternatively, consider that a neural network with polynomial (or analytic) activation function defines a system of equations over R, whose vanishing set is an algebraic (respectively, analytic) variety over R. Of course this goes only a small fraction of the way to closing this gap, but one can start to see how this becomes plausible.

5.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnrefl2yn9dinv)**

See [this paper](https://arxiv.org/abs/1604.03343).

17.

**[^](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fnreflc0m4rnjr2d)**

A frequent perspective is to write this minibatch-loss in terms of its mean (population) value plus some noise term. That is, we think of optimizers like SGD as something like “gradient descent plus noise.” This is quite similar to mathematical models like overdamped Langevin dynamics, though note that the noise term may not be Gaussian as in Langevin dynamics. It is an open question whether the convergence of neural network training is due to the population term or the noise term. (Note that this is a separate question as to whether the generalization / inductive biases of SGD-trained neural networks is due to the population term or the noise term.) I am tentatively of the belief (somewhat controversially) that both convergence and inductive bias is due to structure in the population loss rather than the noise term, but explaining my reasoning here is a bit out of scope.

[Interpretability (ML & AI)1](https://www.lesswrong.com/w/interpretability-ml-and-ai)[Singular Learning Theory1](https://www.lesswrong.com/w/singular-learning-theory)[AI1](https://www.lesswrong.com/w/ai) [Frontpage](https://www.lesswrong.com/posts/5conQhfa4rgb4SaWx/site-guide-personal-blogposts-vs-frontpage-posts)

# 140

Mentioned in

162[Prologue to Terrified Comments on Claude's Constitution](https://www.lesswrong.com/posts/o7e5C2Ev8JyyxHKNk/prologue-to-terrified-comments-on-claude-s-constitution)

[Deep learning as program synthesis](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#)

[11romeostevensit](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#hcYuFDtiXGip75Kjh)

[7voyantvoid](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#b6eQnj8PBsxz5DJxq)

[2Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#rLpYYaddJK6yb9Wpw)

[6ben\_york](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#fcYfKJjEzw7pKKc2g)

[3Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#m8hWSFHXWfFz2q3fJ)

[2ben\_york](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#sicnL5wDoDF7DppNY)

[6epistemic meristem](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#XtYfvyg3nLQSEreL7)

[4epistemic meristem](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#Bw7qpmGkdwuLYN6s2)

[4Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#cdrtkuGJdZtTzcy8C)

[2epistemic meristem](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#XnhrBvZsnahrbiCrk)

[5Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#FpXGMv7k46qiuqNbS)

[4Mlxa](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#6mA6XYEDB3J45mE8f)

[4Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#GgpQErZPTEiQFojaS)

[3ness](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#iY4WuJkNpsPnP64am)

[1Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#2RxXWtKHbaWnWDXEs)

[2Artemy Kolchinsky](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#B7wAsjk9DSynRx9HB)

[2Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#D2qk4iKFLNcnrjeCF)

[2Artemy Kolchinsky](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#RimxXGeGxxwxptTra)

[4Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#6Hvpbd8GemiGnShyW)

[2Artemy Kolchinsky](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#JvicBBRBo6ZHpC4ZQ)

[3Alexander Gietelink Oldenziel](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#FN3nJcCuXeGBBxd8B)

[2davidad](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#yj5vxuq3dB9ZMT7g3)

[1Artemy Kolchinsky](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#ofmsireuStvAdYgDT)

[1Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#NobD4MZdGHp6scwsX)

[1theemptysquare](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#kZj55GY5EhAmKwgBG)

[1xpym](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#QSwwZ6HsZnk9vhYyH)

[0Darmani](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#XXd4H8wuceRx4Xvsw)

[25Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#PLkapewaoQ326YqtH)

[3Darmani](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#p868zrpmgaQhCqAWC)

[23Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#hm4o3vNKLSvhrzz3n)

[6Darmani](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#rxyGPfxQayCzGxHZm)

[9Zach Furman](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#RNhr2MdnWg3xjoXdK)

[5Darmani](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#w9inNMqmLioYx78kN)

New Comment

Normal

Insert

Type here! Use '/' for editor commands.

Submit

33 comments, sorted by
top scoring
Click to highlight new comments since: Today at 4:45 PM

\[-\][romeostevensit](https://www.lesswrong.com/users/romeostevensit)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=hcYuFDtiXGip75Kjh)11

0

Thank you, I've consistently found your posts clarifying.

Reply

![](https://www.lesswrong.com/reactionImages/nounproject/noun-heart-1212629.svg)1

\[-\][voyantvoid](https://www.lesswrong.com/users/voyantvoid)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=b6eQnj8PBsxz5DJxq)7

3

Have you read "Why does deep and cheap learning work so well?" It's referenced in "When and Why Are Deep Networks Better than Shallow Ones?", I liked the explanation of how the hierarchical nature of physical processes mean that the subset of functions we care about will tend to have a hierarchical structure and so be well-suited for deep networks to model.

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=rLpYYaddJK6yb9Wpw)2

0

Yes, this is a great paper, and one of the first papers that put me on to the depth separation literature. Can definitely recommend.

Re: "the explanation of how the hierarchical nature of physical processes mean that the subset of functions we care about will tend to have a hierarchical structure and so be well-suited for deep networks to model," I think this is a fascinating topic, and there's much to be said here. My personal view here is that this question (but not the answer) is essentially equivalent to the physical Church-Turing thesis: somehow, reality is something that can _universally_ be well-described by compositional procedures (i.e. programs). Searching around for "explanations of the physical Church-Turing thesis" will point you to a wider literature in physics and philosophy on the topic.

Reply

\[-\][ben\_york](https://www.lesswrong.com/users/ben_york)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=fcYfKJjEzw7pKKc2g)6

5

Hi Zach. Thanks for such a nice post. The degeneracies seem crucial to the apparent simplicity bias. Does footnote 15 imply that somehow the parameter vector works its way to a certain part of the parameter space, where it gets stuck because the loss function gradients can't steer it out? Also, does this interpretation mean that simplicity is related to (or even more accurately described as) robustness, which would make intuitive sense to me. In this case different measures of simplicity could be reframed as measures of robustness to different types of perturbation.

Reply

![](https://www.lesswrong.com/reactionImages/nounproject/check.svg)1![](https://www.lesswrong.com/reactionImages/nounproject/bullseye.svg)1

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=m8hWSFHXWfFz2q3fJ)3

0

Great questions, thank you!

> Does footnote 15 imply that somehow the parameter vector works its way to a certain part of the parameter space, where it gets stuck because the loss function gradients can't steer it out?

Yes, this is correct, because (as I explain briefly in the "search problem" section) the loss function factors as a composition of the parameter-function map and the function-loss map, so by chain rule you'll always get zero gradient in degenerate directions. (And if you're _near_ degenerate, you'll get _near_-zero gradients, proportional to the degree of degeneracy.) So SGD will find it hard to get unstuck from degeneracies.

This is actually how I think degeneracies affect SGD, but it's worth mentioning that this isn't the only mechanism that could be possible. For instance, degeneracies also affect Bayesian learning (this is precisely the classical SLT story!), where there are no gradients at all. The reason is that (by the same chain rule logic) the loss function is "flatter" around degeneracies, creating an implicit prior by dedicating more of parameter space to more degenerate solutions. Both mechanisms push in the same direction, creating an inductive bias favoring more degenerate solutions.

> Also, does this interpretation mean that simplicity is related to (or even more accurately described as) robustness, which would make intuitive sense to me. In this case different measures of simplicity could be reframed as measures of robustness to different types of perturbation.

This is basically correct, and you can make this precise. The intuition is that robustness to parameter perturbation corresponds to simplicity because many parameter configurations implement the same effective computation - the solution doesn't depend on fine-tuning.

Singular learning theory measures "how degenerate" your loss function is using a quantity called the _local learning coefficient_, which you can view as a kind of "robustness to perturbation" measure. Section 3.1 of [my paper](https://arxiv.org/abs/2308.12108) explains some of the intuition here. In Bayesian learning, this is basically the unambiguously "correct" measure of (model) complexity, because it literally determines the generalization error / free energy to leading order (Main Formula II, [Watanabe 2009](https://www.cambridge.org/core/books/algebraic-geometry-and-statistical-learning-theory/9C8FD1BDC817E2FC79117C7F41544A3A)).

Reply

\[-\][ben\_york](https://www.lesswrong.com/users/ben_york)[2mo\*](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=sicnL5wDoDF7DppNY)2

0

Thanks for your reply. It's a fascinating topic and I've got lots of follow-up questions but I'll read the paper and book first to get a better idea of which questions have already been addressed.

(edit 2 days later): Whoah. There's a lot of material in the book, in your paper and in those from your research group. I didn't realize that one could say so much about flatness! It's very likely I have misunderstood, but are you guys talking about why a model seems to end up on a particular part of a (high dimensional) ridge/plateau of the loss function? The relationship between parameter perturbations and data perturbations is interesting. Do you think robustness to parameter perturbations is acting as a proxy for robustness to data perturbations, which is what we really want? Also, on a more technical note, is the Hironaka Theorem of use when the loss function is effectively piecewise quadratic? Are you concerned that collapsing down so a simple/robust program/function appears to be a one-way process (i.e. it doesn't look like you could undo it)?

There are too many questions here and there's no obligation to answer them. I will continue reading around the topic when I have time. Perhaps one day I can write things up for sharing.

Program synthesis is an interesting direction to take these ideas. I hope it pays off. It's pretty hard to judge. I guess animals need to be robust to parts of their nervous system malfunctioning and people need to be robust to parts of their belief system falling through. Compartmentalisation of the programs/concepts would help with this.

Reply

\[-\][epistemic meristem](https://www.lesswrong.com/users/epistemic-meristem)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=XtYfvyg3nLQSEreL7)6

1

Excellent post!  Related: ["Why Not Sparse Hierarchical Graph Learning"](https://www.beren.io/2025-03-01-Why-Not-Sparse-Hierarchical-Graph-Learning) by [@beren](https://www.lesswrong.com/users/beren-1?mention=user).

Reply

![](https://www.lesswrong.com/reactionImages/nounproject/check.svg)1

\[-\][epistemic meristem](https://www.lesswrong.com/users/epistemic-meristem)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=Bw7qpmGkdwuLYN6s2)4

2

> Consider the various models of computation: Turing machines, lambda calculus, Boolean circuits, etc. They have different primitives - tapes, substitution rules, logic gates - but the Church-Turing thesis tells us they're equivalent.

Nit: the standard notion of Boolean circuit isn't Turing-complete.

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=cdrtkuGJdZtTzcy8C)4

2

Yeah, good catch - the correct notion here is a (uniform) _family_ of Boolean circuits, which are Turing-complete in the sense that every uniform circuit family decides a decidable language, and every decidable language can be decided by a uniform circuit family. (Usefully, they also preserve complexity theory: for example, a language is in P if and only if it can be decided by a P-uniform polynomial-size circuit family.)

Reply

\[-\][epistemic meristem](https://www.lesswrong.com/users/epistemic-meristem)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=XnhrBvZsnahrbiCrk)2

0

(Though that notion assumes a Turing machine under the hood, so it's not a full-fledged alternative model of computation like lambda calculus.)

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=FpXGMv7k46qiuqNbS)5

0

Agreed. I guess the small saving grace (as I'm sure you know) is that the TM under the hood is used to _limit_ the computational power of the family rather than contribute to it. But yeah that part is kind of ugly.

Reply

\[-\][Mlxa](https://www.lesswrong.com/users/mlxa)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=6mA6XYEDB3J45mE8f)4

0

One of the specific cases of feature learning mystery is MLP being able to learn sparse parities, i.e. output is XOR of some k bits of the input which is n bits in total, and MLP is able to learn this in close to O(n^k), which is actually the computational limit here. In [this paper](https://proceedings.neurips.cc/paper_files/paper/2022/file/884baf65392170763b27c914087bde01-Paper-Conference.pdf) they give a very nice intuition (Section 4.1) about why even in a network with a single layer (and ReLU on top of it) gradients will contain some information about the solution.
TLDR: Gradient of "ReLU of the sum of incoming activations", if we consider incoming weights all being one (that's the example they study), is just a majority function. And an interesting property of majority function is that contribution of k-wise feature interactions to it decays exponentially with k. And because of this decay gradients end up being informative.

There was also an interesting paper about limitations of gradient optimization, which I can't find now. One of the examples there was a task which is basically a XOR of k simple image classification problems (something about detecting angle of a line from the image). And they show that without intermediate target (i.e. target for a single classification task instead of XOR of all of them) it stops learning around k=4, while with intermediate target it can go up to k=20. Which is to say that even in cases where there is a compact structure in the problem, neural networks (and maybe any gradient-based models) will not always be able to find it quickly.

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=GgpQErZPTEiQFojaS)4

0

Thank you for bringing this up, the story of learning dynamics is a fascinating one and something I didn't get the time to treat properly in the post. There really is (at least in theory) quite a substantial gap between Bayesian learning (what Solomonoff uses) and SGD learning.

A favorite example of mine is the task of learning pseudorandom functions: these cannot be learned in polynomial time, else you could distinguish pseudorandom numbers from random numbers and break cryptography. So because SGD training runs in polynomial time, it’s impossible for SGD training to find a pseudorandom function easily. Bayesian learning (which does not run in polynomial time) on the other hand _would_ find the pseudorandom function quite quickly, because you can literally hardcode a psuedorandom generator into the weights of a sufficiently large neural network (Bayes is sort of “omnipotent” over the entire parameter space).

As you mention, learning parities are another great example of a task which is easy for Bayes but hard for SGD (though the reason is different from pseudorandom functions). There is a highly rich literature here, including the [paper](https://proceedings.neurips.cc/paper_files/paper/2022/file/884baf65392170763b27c914087bde01-Paper-Conference.pdf) you linked by Barak which is a favorite of mine. Another personal favorite is the later paper on [leap complexity](https://arxiv.org/abs/2302.11055), which shows how the structure of these computational obstacles may give SGD learning a "hysteresis" or "history dependent" effect - learning earlier things shapes what things you learn later, something which doesn't happen at all for Bayes.

Reply

![](https://www.lesswrong.com/reactionImages/nounproject/check.svg)1

\[-\][ness](https://www.lesswrong.com/users/ness)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=iY4WuJkNpsPnP64am)3

0

Is there a version of this post for people with background in algebraic geometry and higher categories?

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=2RxXWtKHbaWnWDXEs)1

1

The short answer is: no, but hopefully in the future. The long answer is: oh man, that was the post(s) I originally planned to write, this post was originally something of a preface that I thought would take a few hours, and it took >100, so... we'll see if I can muster the effort. For now, you might get something out of looking into [singular learning theory](https://www.lesswrong.com/posts/xRWsfGfvDAjRWXcnG/dslt-0-distilling-singular-learning-theory), and possibly the papers I referenced [in](https://arxiv.org/abs/2207.10871)[the](https://arxiv.org/abs/2502.08911)[post](https://arxiv.org/abs/2504.08075), though I'm very much abruptly throwing you into the deep end here (apologies).

Reply

\[-\][Artemy Kolchinsky](https://www.lesswrong.com/users/artemy-kolchinsky)[2mo\*](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=B7wAsjk9DSynRx9HB)2

0

Thanks for this note, I really enjoyed reading it.

One terminological point: I'm a bit confused by your use of "program" / "effective program", especially where you contrast "programs" with "neural networks". In algorithmic information theory, a program is any string that computes a function on a UTM. Under that definition, a particular neural network (topology + weights, plus maybe a short 'interpreter') already is a program. The fact that weights are often modeled as continuous, while UTM inputs are discrete, doesn't seem like a key difference, since weights are always discretized in practice.

So, I suspect your discussion of "finding short programs" is more about "finding simple functions", i.e., low Kolmogorov-complexity functions with short compressed descriptions. That reformulation also makes more sense in light of generalization, since generalization is a property of the computed function, not the specific implementation (a lookup-table and a Fourier-style implementation of modular arithmetic generalize the same way, if they compute the same function).

In Solomonoff induction, the distinction between "finding short programs" and "finding simple functions" doesn't really matter, since they end up being essentially the same. However, it seems this distinction is important in the setting of machine learning, where we are literally searching over a space of programs (parameterized neural networks) that all have the same description length (number of parameters \* precision).

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=D2qk4iKFLNcnrjeCF)2

0

Hey Artemy, glad you enjoyed the post!

Thanks for this comment, I think this is a pretty crucial but subtle clarification that I hard time conveying.

You're right that there's some tension here. A neural network already trivially _is_ a program. And you're right that in Solomonoff induction, "short program" and "simple function" collapse together by definition.

But I think the reformulation to "finding simple functions" loses something crucial. The key is that there's a three-layer picture, not two:

**Parameters -> Effective Program -> Function**

I tried to gesture at this in the post:

> The network's architecture trivially has compositional structure—the forward pass is executable on a computer. That's not the claim. The claim is that training discovers an effective program _within_ this substrate. Think of an FPGA: a generic grid of logic components that a hardware engineer configures into a specific circuit. The architecture is the grid; the learned weights are the configuration."

As in, an FPGA configuration doesn't directly specify a function - it specifies a _circuit_, which then computes a function. All configurations have the same bit-length, but the circuits they implement vary enormously in complexity. You make the effective circuit simpler than the full substrate with dead logic blocks, redundant paths, etc.

Now, when it comes to neural networks, all networks in an architecture class have the same parameter count, as you note. But through degeneracies (dead neurons, low-rank weights, redundant structure, and a whole lot more), the "effective program" can be far simpler than the parameter count suggests.

Now, why does this middle layer matter? Why not just talk about functions directly?

Because there's no notion of function simplicity that doesn't route through implementations. To say a function is "simple" (low Kolmogorov complexity) is to say there exists a short program computing it. But "exists" quantifies over all possible programs. Gradient descent doesn't get access to that - it only sees the implementation it actually has, and the immediate neighborhood in parameter space. Two programs computing the same function aren't interchangeable from the learner's perspective; only one of them is actually in front of you, and that's what determines where you can go next.

This means two parameter configurations that implement _literally the same function everywhere_ can still behave completely differently under training. They sit at different points in the loss landscape. They have different stability properties. They're differently accessible from other regions of parameter space. The learning process distinguishes them even though the function doesn't. (The concrete mechanism is the parameter-function map; the loss is the same if the function is the same, but the gradients are not.)

This is why I actually think it's important to stick with "finding simple (effective) programs" over "finding simple functions," as the distinction really does matter.

Now of course, making precise what "effective program" even means is not obvious at all. That's where I start talking about singular learning theory :)

Reply

\[-\][Artemy Kolchinsky](https://www.lesswrong.com/users/artemy-kolchinsky)[2mo\*](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=RimxXGeGxxwxptTra)2

0

Thanks, I think I see your point! Still, it seems important to be clear that the core claim -- that neural networks are biased toward learning functions with better generalization -- is ultimately a claim about the learned function. If I understand correctly, you’re offering one explanation for why this might happen: training induces an implicit search over “effective programs,” and that search has a simplicity bias.

I’m wondering whether your argument can be framed via an analogy to Solomonoff induction. In standard Solomonoff induction, among the functions consistent with the training data, a function’s weight is proportional to the probability that it is computed by a universal Turing machine fed with random bits (for prefix-free machines, this yields a bias toward shorter prefixes). Are you thinking of something analogous  for neural networks: among functions consistent with the data, a function’s weight is proportional to the probability that it is computed by a neural-network interpreter when fed with random weights?

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=6Hvpbd8GemiGnShyW)4

0

> Still, it seems important to be clear that the core claim -- that neural networks are biased toward learning functions with better generalization -- is ultimately a claim about the learned function.

If I understand correctly, I completely agree, with one small nit: "generalization" isn't really a property of a function in isolation - it's a property of a learning setup. A function just is what it is; it doesn't generalize or fail to generalize.

But if I understand what you mean correctly, you're saying something like: "neural networks are biased toward learning functions that perform well on real-world tasks." I think this is very important point that should be emphasized. This requires two things to work together: (1) the learner has a simplicity bias, and (2) real-world tasks preferentially admit simple solutions. Neither alone is enough.

And I think you're pointing to the fact that (2) still needs explanation, which is true. It's ultimately a property of the real-world, not neural networks, so you need some kind of model-independent notion of "simplicity" like Kolmogorov complexity to make this even coherent. I would 100% agree. There's more I could say here but it rapidly gets speculative and probably a longer discussion.

> In standard Solomonoff induction, among the functions consistent with the training data, a function’s weight is proportional to the probability that it is computed by a universal Turing machine fed with random bits (for prefix-free machines, this yields a bias toward shorter prefixes). Are you thinking of something analogous for neural networks: among functions consistent with the data, a function’s weight is proportional to the probability that it is computed by a neural-network interpreter when initialized fed with random weights?

This is a really sharp question, thank you. I think there's certainly a _Bayesian_ story of neural networks you could tell here which would work exactly like this (in fact I believe there's some in-progress SLT work in this direction). I think there's a good chance this is like 80% of the story.

But there's some ways that we know SGD must be different. For instance, Bayes should give pseudorandom functions some nontrivial prior weight (they exist in parameter space, they can be hardcoded into the parameters), but SGD will basically never find them (see my discussion on Mixa's comment). So I think ultimately you need to talk about learning dynamics. Here is also a place where there's a lot more I could say (I think there's decent evidence as to _what_ ways SGD differs in the programs it prefers), but it's a longer discussion.

Reply

![](https://www.lesswrong.com/reactionImages/nounproject/check.svg)1![](https://www.lesswrong.com/reactionImages/nounproject/bullseye.svg)1

\[-\][Artemy Kolchinsky](https://www.lesswrong.com/users/artemy-kolchinsky)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=JvicBBRBo6ZHpC4ZQ)2

0

> This is a really sharp question, thank you. I think there's certainly a _Bayesian_ story of neural networks you could tell here which would work exactly like this (in fact I believe there's some in-progress SLT work in this direction). I think there's a good chance this is like 80% of the story.

Interesting! Are you familiar with the paper "[Deep neural networks have an inbuilt Occam’s razor"](https://www.nature.com/articles/s41467-024-54813-x.pdf), itself building on the work of "[Input–output maps are strongly biased towards simple outputs](https://www.nature.com/articles/s41467-018-03101-6.pdf)" by Dingle et al.? I feel like it may be getting at something closely related.

Reply

\[-\][Alexander Gietelink Oldenziel](https://www.lesswrong.com/users/alexander-gietelink-oldenziel)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=FN3nJcCuXeGBBxd8B)3

0

Hi Artemy. Welcome to LessWrong!

Agree completely with what Zach is saying here.

We need two facts

(1) the world has a specific inductive bias

(2) neural networks have the same specific inductive bias

Indeed no free lunch arguments seem to require any good learner to have good inductive bias. In a sense learning is 'mostly' about having the right inductive bias.

We call this specific inductive bias a simplicity bias. Informally it agrees with our intuitive notion of low complexity.

Rk. Conceptually it is a little tricky since simplicity is in the eye of the beholder - by changing the background language we can make anything with high algorithmic complexity have low complexity. People have been working on this problem for a while but at the moment it seems radically tricky.

IIRC Aram Ebtekar has a proposed solution that John Wentworth likes; I haven't understood it myself yet. I think what one wants to say is that the \[algorithmic\] mutual information between the observer and the observed is low, where the observer implicitly encodes the universal turing machine used. In other words - the world is such that observers within it observe it to have low complexity with regard to their implicit reference machine.

Regardless, the fact that the real world satisfies a simplicity bias is to my mind difficult to explain without anthropics. I am afraid we may end up having to resort to an appeal to some form of UDASSA but others may have other theological commitments.

* * *

That's the bird-eye view of simplicity bias. If you ignore the above issue and accept some sort of formally-tricky-to-define but informally "reasonable" simplicty then the question becomes: why do neural networks have a bias towards simplicity. Well they have a bias towards degeneracy - and simplicity and bias are intimiately connected, see eg:

https://www.lesswrong.com/posts/tDkYdyJSqe3DddtK4/alexander-gietelink-oldenziel-s-shortform?commentId=zH42TS7KDZo9JimTF

Reply

\[-\][davidad](https://www.lesswrong.com/users/davidad)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=yj5vxuq3dB9ZMT7g3)2

0

“Some form of UDASSA” seems to be right. Why not simply take “difficult to explain otherwise” as evidence (defeasible, of course, like with evidence of physical theories)?

Reply

![](https://www.lesswrong.com/reactionImages/nounproject/check.svg)1

\[-\][Artemy Kolchinsky](https://www.lesswrong.com/users/artemy-kolchinsky)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=ofmsireuStvAdYgDT)1

0

Alex, thanks for the welcome (happy to be here!) and the summary.

I'm generally familiar with this line of thought. My main comment is that the Solomonoff perspective feels somewhat opposite to the usual NFL/“inductive bias” story (where the claim is that a good image model needs a good prior over image statistics, etc.). Yes, a simplicity bias is a kind of inductive bias, but it’s supposed to be universal (domain independent). And if generic architectures really give us this prior “for free”, as suggested by results like Dingle et al., then it seems the hard part isn’t the prior, but rather being able to sample from it conditioned on low training error (i.e., the training process).

That said, this line of reasoning -- if taken literally -- seems difficult to reconcile with some observed facts, e..g, things like architecture choice and data augmentation do seem to matter for generalization. To me, these suggest that you need some inductive bias beyond algorithmic simplicity alone. (Possibly another way to think about it: the smaller the dataset, the more the additive constant in Kolmogorov complexity starts to matter.)

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=NobD4MZdGHp6scwsX)1

0

Yeah, I've seen those! They do express similar ideas, and I think Chris does serious work. I completely agree with the claim "the parameter-function map is strongly biased towards simple functions," basically for SLT reasons (though one has to be careful here to avoid saying something tautological, it's not as simple as "SLT says learning is biased towards lower LLC solutions, therefore it has a simplicity bias").

There's a good [blog post](https://www.lesswrong.com/posts/5p4ynEJQ8nXxp2sxC/parsing-chris-mingard-on-neural-networks) discussing this work that I read a few years ago. _Keeping in mind I read this three years ago and so this might be unfair_, I remember my opinion on that specific paper being something along the lines of "the ideas are great, the empirical evidence seems okay, and I don't feel great about the (interpretation of the) theory." In particular I remember reading [this](https://www.lesswrong.com/posts/5p4ynEJQ8nXxp2sxC/parsing-chris-mingard-on-neural-networks?commentId=sFC9oJjC3EAbrBujb) comment thread and agreeing with the perspective of interstice, for whatever that's worth. But I could change my mind.

Reply

\[-\][theemptysquare](https://www.lesswrong.com/users/theemptysquare)[25d](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=kZj55GY5EhAmKwgBG)1

0

This is an excellent piece of work and I believe correct in a fundamental, multi-dimensional way. I've been writing on exactly this - the geometric structure that emerges from these interconnected algorithms and what it means for what's running inside these systems. These algorithms you're talking about - these "programs" - are not simple "hello world". They are algorithms that pick on the results of other algorithms. The entire LLMs is seeded with these, aligned in multi-dimensional space and vitally, they connect to one another. You have these in "layers" or manifolds, and they make use of one another. This creates a fundamental geometric structure which guides the apparent cognition these models generate. It also explains their long-range and multiple-prompt coherence in reasoning, because the geometric structure is constraining the local randomness and guiding it along a coherent path.

Reply

\[-\][xpym](https://www.lesswrong.com/users/xpym)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=QSwwZ6HsZnk9vhYyH)1

-9

> Second, deep learning works in practice, using a reasonable amount of computational resources; meanwhile, even the most efficient versions of Solomonoff induction like speed induction run in exponential time or worse.

But doesn't increasing the accuracy of DL outputs require exponentially more compute? It only "works" to the extent that labs have been able to afford exponential compute scaling so far.

Reply

\[-\][Darmani](https://www.lesswrong.com/users/darmani)[2mo\*](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=XXd4H8wuceRx4Xvsw)0

-17

Hi! I did my Ph. D. in a program synthesis lab that later become a mixed program synthesis / machine learning lab. "Machine learning is program synthesis under a different name" my advisor would say.

But my experienced turned out to not be very relevant to reading this post, because, I must say...I did not get what the point of this post is or the intended takeaways.

In genetic programming, there's a saying "Learning programs is generalized curve-fitting." And, indeed, the first chapter of "Foundations of Genetic Programming" is about trying to evolve a small AST that fits a curve. I gave a similar problem to my students as their intro to enumerative program synthesis.

As far as I can tell, that's the entire meat of this post. Programs can be scene as fancy curves. Okay, I see a few paragraphs about that, plus pages and pages of math tangents. What else am I supposed to get from reading?

To be a little more blunt, reading this reminded me of the line "The book 'Cryptonomicon' is 1000 pages of Neal Stephenson saying 'Hey, isn't this cool'" as he goes into random digressions into basic cryptography, information theory, etc.  Yes, the mechanistic interpretability of grokking is cool. Yes, it's cool that it's connected to representation theory. No, I have no idea how that's related to any larger thesis in this post.

BTW, you'll probably find the keyword "program induction" more fruitful than "program synthesis." Program synthesis is a PL/FM term that usually refers to practical techniques for generating programs (or other objects that can be phrased as programs) from specs, examples, human feedback, existing code, etc. "Program induction" is an ML term that basically refers to what you're talking about: the philosophy of supervised learning being "learning programs."

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=PLkapewaoQ326YqtH)25

6

> As far as I can tell, that's the entire meat of this post. Programs can be scene as fancy curves. Okay, I see a few paragraphs about that, plus pages and pages of math tangents. What else am I supposed to get from reading?

I think you've pattern-matched this to a claim I'm not making, and in fact the claim runs in the opposite direction from what you describe.

You write: "Programs can be seen as fancy curves." Call this Claim A: program synthesis is a special case of function approximation. Programs are functions, so searching for programs is searching for functions. That's almost trivially true.

But the post is arguing Claim B: deep learning - which looks like generic function approximation - is actually implementing something like Solomonoff induction. These aren't the same claim. Claim A is obvious; Claim B is surprising and non-obvious.

Not all function approximation is program synthesis. Polynomial regression isn't "secretly doing program synthesis" in any non-trivial sense. Neither are kernel methods, decision trees, or genetic programming on fixed AST grammars. These are narrow hypothesis classes where you, the practitioner, chose a representation embedding your assumptions about problem structure. I explicitly address this in the post:

> Two things make this different from ordinary function fitting.
>
> First, the search is **general-purpose**. Linear regression searches over linear functions. Decision trees search over axis-aligned partitions. These are narrow hypothesis classes, chosen by the practitioner to match the problem. The claim here is different: deep learning searches over a space that can express essentially any efficient computable function. It's not that networks are good at learning one particular kind of structure - it's that they can learn whatever structure is there.
>
> Second, the search is guided by **strong inductive biases**. Searching over all programs is intractable without some preference for certain programs over others. The natural candidate is simplicity: favor shorter or less complex programs over longer or more complex ones. This is what Solomonoff induction does - it assigns prior probability to programs based on their length, then updates on data.

The puzzle isn't "how does function approximation relate to programs?" The puzzle is: how could gradient descent on a deep neural network possibly behave like a simplicity-biased search over programs, when we never specified that objective, and when we don't know how to do that efficiently (poly-time) ourselves? The remarkable thing about deep learning is that it searches a universal hypothesis class and somehow doesn't drown in it.

> I did not get what the point of this post is or the intended takeaways.

I write at the beginning that I see this as "a snapshot of a hypothesis that seems increasingly hard to avoid, and a case for why formalization is worth pursuing. I discuss the key barriers and how tools like singular learning theory might address them towards the end of the post." That is, I am 1. making a hypothesis about how deep learning works, and 2. attempting to sketch research directions that aim to formally nail down the hypothesis.

> BTW, you'll probably find the keyword "program induction" more fruitful than "program synthesis."

This is a good point on terminology - I did go back and forth. "Program induction" is closer to the most relevant existing literature, but I chose "synthesis" deliberately. "Induction" implies sequence prediction and doesn't extend naturally to settings like RL. But the bigger reason I chose "synthesis": I expect deep learning is doing something closer to constructing programs than enumerating over them. Gradient descent seems not to be (and couldn't possibly be) doing brute-force search through program space, but rather building something incrementally. That's the sharpest break I expect from Solomonoff, and "synthesis" seems to gesture at it better than "induction" does. But I could be convinced to change my mind.

Reply

\[-\][Darmani](https://www.lesswrong.com/users/darmani)[2mo\*](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=p868zrpmgaQhCqAWC)3

-3

Hmmm. Okay then, I'd like to understand your point.

But first, can we clear up some terminological confusion?

From this comment, it seems you are using "program synthesis" in ways which are precisely the opposite of its usual meaning. This means I need to do substantial reverse-engineering of what you mean in every line, in addition to trying to understand your points directly.

> These are narrow hypothesis classes where you, the practitioner, chose a representation embedding your assumptions about problem structure.

This is a very confusing thing to write. I think you're saying that various techniques are differentiated from program synthesis because they "choose a representation embedding assumptions about the problem structure." But can you point to any papers in the program synthesis literature which don't do this?

> But the bigger reason I chose "synthesis": I expect deep learning is doing something closer to constructing programs than enumerating over them. Gradient descent seems not to be (and couldn't possibly be) doing brute-force search through program space,

I think you're saying that you use the term "program synthesis" to mean "things that are not brute-force searches over program space."

But a brute-force search over program space is a perfectly valid synthesis technique! It's literally the first technique discussed in my advisor's Intro to Program Synthesis course. See [https://people.csail.mit.edu/asolar/SynthesisCourse/Lecture2.htm](https://people.csail.mit.edu/asolar/SynthesisCourse/Lecture2.htm) (scroll down to "Explicit Enumeration").

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=hm4o3vNKLSvhrzz3n)23

2

I think we're talking past each other and getting stuck on terminology. Let me be more explicit about what the thesis is contrasting with, without the contested terms.

The default view of neural networks - the one implicit in most ML theory and practice - is that they're black-box function approximators. The Universal Approximation Theorem says they can represent any continuous function given enough parameters. We train them end-to-end, we don't know what the weights mean, and we don't expect them to mean anything in particular. They're solutions to an optimization problem, not representations of anything.

The thesis is that this view is wrong, or at least deeply incomplete. When we look inside trained networks (mechanistic interpretability), we find compositional, algorithm-like structures: edge detectors composing into shape detectors composing into object detectors; a transformer learning a Fourier-based algorithm for modular addition. These aren't arbitrary learned functions - they look like programs built from reusable parts.

The claim is that this is not a coincidence. Deep learning succeeds because it's finding such structures, because it's performing something like a simplicity-biased search over a universal hypothesis class of compositional solutions (read: space of programs). This sounds a lot like Solomonoff induction, which we already know is the theoretical ideal of supervised learning. That is: what if secretly deep learning is performing a tractable approximation to the learning algorithm we already know is optimal?

If you already take it as obvious that "learning is finding programs," even when it comes to deep neural networks, then yes, much of the post will seem like elaboration rather than argument. But that's not the mainstream view in ML, and the evidence that networks actually learn interpretable compositional algorithms is relatively recent and not widely appreciated.

Does that clarify where the thesis is coming from?

Reply

\[-\][Darmani](https://www.lesswrong.com/users/darmani)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=rxyGPfxQayCzGxHZm)6

-2

Thanks for the clarification Zach!

Since I've been accused of lazy reading, I want to finish off the terminological discussion and put you in my shoes a bit. I get your motivation for preferring to call it "program synthesis" over "program induction," but it turns out that's an established term with about 60 years of history. Basically, to understand how I read it: replace every use of "program synthesis" with "techniques for searching constrained spaces of programs using things like SAT solvers and Monte Carlo." If you also replace "Daniel Selsam" with "researcher in SAT solvers who started off in a lab that uses Monte Carlo to generate assembly programs," then I actually think it becomes hard _not_ to read it the way that I did -- the way that you said was the opposite of the intended reading. And there aren't really any clear cues that you are not talking about program synthesis in the existing sense -- no clear "I define a new term" paragraph. You might think that the lack of citation to established synthesis researchers would be a tell, but, unfortunately, experience has taught me that's fairly weak evidence of such.

So I read it again, this time replacing "program synthesis" with "Solomonoff induction." It does indeed read very differently.

And I read your last comment.

And my main reaction was: "Wait, you mean many people _don't_ already see things this way?"

I mean, it's been a full decade since Jacob Andreas defended his thesis on modularity in neural networks. I just checked his Google Scholar. First paper (>1600 citations, published 2016), abstract, first sentence: "Visual question answering is fundamentally compositional in nature."

If neural nets are not doing a simplicity-biased search over compositional solutions, then what are they doing? Finding the largest program before the smaller ones? Not obtaining intermediate results? Not sharing substructure across tasks while still using a smaller number of weights? Developing novel algorithms that solve the problem in one-shot without any substeps?

I'd naively expect neural nets to, by default, be about as modular as biological systems, or programs evolved with GP. In many ways, very modular, but also with a lot of crazy coupling and fragility. Neural nets gain efficiency over GP by being able to start with a superposition of a vast number of solutions and grow or shrink many of them simultaneously. They also can be given stronger regularization than in biology. I would expect them to find a simple-ish solution but not the simplest. If they only found the most complex ones, that would be way more impressive.

Reply

\[-\][Zach Furman](https://www.lesswrong.com/users/zach-furman)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=RNhr2MdnWg3xjoXdK)9

0

> "Wait, you mean many people don't already see things this way?"

I _wish_ this were obvious :). But it's 2026 and we're still getting op-eds from professors arguing that LLMs are "stochastic parrots" or "just shallow pattern-matching." I wish I could tell laypeople "the scientific consensus is that this is wrong," but I can't because there isn't one. The scaling hypothesis was a fringe position five years ago and remains controversial today. "No free lunch" and "deep learning will just overfit" were standard objections until embarrassingly recently, and you'll still hear them occasionally.

If (a tractable approximation to) the provably optimal learning algorithm isn't "real learning," I don't know what would be. Yet clearly many smart people don't believe this. And this leads to seriously different expectations about where the field will go: if deep learning is implementing something like Solomonoff induction, the default expectation shifts toward continued scaling - not to say that scaling _must_ work (efficiency limits, data constraints, a thousand practical issues could intervene), but because there's no in-principle reason to expect a hard ceiling. That's something people still dispute, loudly.

That being said, as I mention at the beginning, these ideas aren't new or original to me, and some people do believe versions of these sorts of claims. Let me crudely break it down into a few groups:

**Average ML practitioner / ICLR attendee**: The working assumption is still closer to "neural networks do black-box function approximation," maybe with vague gestures toward "feature learning" or something. They may be aware of mechanistic interpretability but haven't integrated it into their worldview. They're usually only dimly aware of the theoretical puzzles if at all (why doesn't the UAT construction work? why does the same network generalize on real data and memorize random labels?).

**ML theory community**: Well ... it depends what subfield they're in, knowledge is often pretty siloed. Still, bits and pieces are somewhat well-known by different groups, under different names: things like compositionality, modularity, simplicity bias, etc. For instance, Poggio's group put out a great [paper](https://arxiv.org/abs/1611.00740) back in 2017 positing that compositionality is the main way that neural networks avoid the curse of dimensionality in approximation theory. Even then, I think these often remain isolated explanations for isolated phenomena, rather than something like a unified thesis. They're also not necessarily consensus - people still propose alternate explanations to the generalization problem in 2026! The idea of deep learning as a "universal" learning algorithm, while deeply felt by some, is rarely stated explicitly, and I expect would likely receive substantial pushback ("well deep learning performs badly in X scenario where I kneecapped it"). Many know of Solomonoff induction but don't think about it in the context of deep learning.

**Frontier labs / mechanistic interpretability / AIT-adjacent folks**: Here, "deep learning is performing something like Solomonoff induction" wouldn't make anyone blink, even if they might quibble with the details. It's already baked into this worldview that deep learning is some kind of universal learning algorithm, that it works by finding mechanistic solutions, that there are few in-principle barriers. But even in this group, many aren't aware of the totality of the evidence - e.g. I talked to an extremely senior mech interp researcher who wasn't aware of the approximation theory / depth separation evidence. And few will defend the hypothesis in public. Even among those who accept the informal vibes, far fewer actively think the connection could possibly be made _formal_ or true in any precise sense.

So: the post isn't claiming novelty for the hypothesis (I say this explicitly at the start). It's trying to put the evidence in one place, say the thing outright in public, and point toward formalization. If you're already in the third group, much of it will read as elaboration. But that's not where most people are.

Reply

\[-\][Darmani](https://www.lesswrong.com/users/darmani)[2mo](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1?commentId=w9inNMqmLioYx78kN)5

0

Thank you! This really made your thesis click for me.

Reply

![](https://www.lesswrong.com/reactionImages/nounproject/thankyou.svg)1

[Moderation Log](https://www.lesswrong.com/moderation)

More from[Zach Furman](https://www.lesswrong.com/users/zach-furman)

98[Singular learning theory: exercises](https://www.lesswrong.com/posts/3HYqTAi4kD35G3BzQ/singular-learning-theory-exercises)

[Zach Furman](https://www.lesswrong.com/users/zach-furman)
2y

6

77[Approximation is expensive, but the lunch is cheap](https://www.lesswrong.com/posts/gq9GR6duzcuxyxZtD/approximation-is-expensive-but-the-lunch-is-cheap)

[Jesse Hoogland](https://www.lesswrong.com/users/jesse-hoogland), [Zach Furman](https://www.lesswrong.com/users/zach-furman)
3y

3

37[Learning coefficient estimation: the details](https://www.lesswrong.com/posts/9ecpBaAiGQnkmX9Ex/learning-coefficient-estimation-the-details)

[Zach Furman](https://www.lesswrong.com/users/zach-furman)
2y

0

[View more](https://www.lesswrong.com/users/zach-furman)

Curated and popular this week

145[Some things I noticed while LARPing as a grantmaker](https://www.lesswrong.com/posts/CzoiqGzpShprcv2Jd/some-things-i-noticed-while-larping-as-a-grantmaker)

[Zach Stein-Perlman](https://www.lesswrong.com/users/zach-stein-perlman)
1d

8

223[Gyre](https://www.lesswrong.com/posts/LEzENY5brcNXfB9aX/gyre)

[vgel](https://www.lesswrong.com/users/vgel)
4d

21

173[Lesswrong Liberated](https://www.lesswrong.com/posts/hj2NTuiSJtchfMCtu/lesswrong-liberated-1)

[Ronny Fernandez](https://www.lesswrong.com/users/ronny-fernandez)
2d

118

[33Comments](https://www.lesswrong.com/posts/Dw8mskAvBX37MxvXo/deep-learning-as-program-synthesis-1#comments)

33

x

Deep learning as program synthesis — LessWrong

reCAPTCHA

Recaptcha requires verification.

protected by **reCAPTCHA**