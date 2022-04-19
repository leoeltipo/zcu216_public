clear all
close all

% Base filter.
load h0.mat

% Mask filter.
load hm.mat

% First stage masking.
h0_i = upsample(h0,2);
h1 = conv(h0_i,hm);

% Second stage masking.
h1_i = upsample(h1,2);
h2 = conv(h1_i,hm);

% Third stage masking.
h2_i = upsample(h2,2);
h3 = conv(h2_i,hm);

% Fourth stage masking.
h3_i = upsample(h3,2);
h4 = conv(h3_i,hm);

% Save filter.
save('h4.mat','h4')

% Quantized filter.
h4_q = fi(h4);

H0 = fft(h0);
H0_i = fft(h0_i);
H1 = fft(h1);
H1_i = fft(h1_i);
H2 = fft(h2);
H2_i = fft(h2_i);
H3 = fft(h3);
H3_i = fft(h3_i);
H4 = fft(h4);
H4_Q = fft(double(h4_q));
HM = fft(hm);

w = linspace(0,2,length(H0));
plot(w, 20*log10(abs(H0))); hold on

w = linspace(0,2,length(H0_i));
plot(w, 20*log10(abs(H0_i)));

w = linspace(0,2,length(H1));
plot(w, 20*log10(abs(H1)));

w = linspace(0,2,length(H1_i));
plot(w, 20*log10(abs(H1_i)));

w = linspace(0,2,length(H2));
plot(w, 20*log10(abs(H2)));

w = linspace(0,2,length(H2_i));
plot(w, 20*log10(abs(H2_i)));

w = linspace(0,2,length(H3));
plot(w, 20*log10(abs(H3)));

w = linspace(0,2,length(H3_i));
plot(w, 20*log10(abs(H3_i)));

w = linspace(0,2,length(H4));
plot(w, 20*log10(abs(H4)));

w = linspace(0,2,length(HM));
plot(w, 20*log10(abs(HM)));

legend('H0','H0_i','H1','H1_i','H2','H2_i','H3','H3_i','H4','HM')

% Final filter.
figure;
w = linspace(0,2,length(H4));
plot(w, 20*log10(abs(H4))); hold on
plot(w, 20*log10(abs(H4_Q)));
legend('H','H_q')

figure
w = linspace(0,2,length(H0));
subplot(211);plot(w, 20*log10(abs(H0)));
title('H_0')

w = linspace(0,2,length(HM));
subplot(212);plot(w, 20*log10(abs(HM)));
title('H_M')
